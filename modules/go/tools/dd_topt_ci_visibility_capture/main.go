package main

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	// defaultListenAddress keeps the proxy local to the wrapped test process.
	defaultListenAddress = "127.0.0.1"
	// defaultUpstreamURL preserves the tracer's normal agent/EVP behavior when no explicit agent URL is set.
	defaultUpstreamURL = "http://localhost:8126"
	// shutdownPollInterval controls how quickly the helper notices the wrapper stop sentinel.
	shutdownPollInterval = 100 * time.Millisecond
	// shutdownTimeout bounds how long the helper waits for in-flight proxy requests during shutdown.
	shutdownTimeout = 2 * time.Second
)

// captureRequestKind describes which Bazel payload directory should receive a copied CI Visibility request.
type captureRequestKind int

const (
	// captureRequestNone marks requests that should only be proxied.
	captureRequestNone captureRequestKind = iota
	// captureRequestTests marks CI test-cycle uploads.
	captureRequestTests
	// captureRequestCoverage marks CI code-coverage uploads.
	captureRequestCoverage
)

// options describes the wrapper-provided runtime configuration for the capture proxy.
type options struct {
	// ListenAddress is the local interface the helper binds for the wrapped test process.
	ListenAddress string
	// PortFile is the file the helper writes once it has successfully chosen a local port.
	PortFile string
	// StopFile is the wrapper-owned sentinel that requests graceful shutdown after the test finishes.
	StopFile string
	// OutputDir is the Bazel undeclared outputs root where captured payload files are written.
	OutputDir string
	// UpstreamURL is the original agent URL the helper proxies to after copying payload bodies.
	UpstreamURL string
}

// captureProxy copies CI Visibility payload requests into Bazel outputs while optionally proxying them upstream.
type captureProxy struct {
	// outputDir is the Bazel undeclared outputs directory for the wrapped test.
	outputDir string
	// upstream is the original agent/EVP base URL the tracer would have used without the local proxy.
	upstream *url.URL
	// client performs the best-effort upstream proxy requests.
	client *http.Client
	// testCount assigns stable file names to captured test payloads.
	testCount atomic.Uint64
	// coverageCount assigns stable file names to captured coverage payloads.
	coverageCount atomic.Uint64
}

// main starts the local capture proxy used by wrapped Go tests.
func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "dd_topt_ci_visibility_capture: %v\n", err)
		os.Exit(1)
	}
}

// run parses wrapper flags and serves the local capture proxy until the wrapper stop signal arrives.
func run(args []string) error {
	cfg, err := parseFlags(args)
	if err != nil {
		return err
	}
	if err := validateOptions(cfg); err != nil {
		return err
	}

	upstreamURL, err := url.Parse(cfg.UpstreamURL)
	if err != nil {
		return fmt.Errorf("parse upstream URL %q: %w", cfg.UpstreamURL, err)
	}

	proxy := &captureProxy{
		outputDir: cfg.OutputDir,
		upstream:  upstreamURL,
		client: &http.Client{
			Timeout: 10 * time.Second,
		},
	}

	listener, err := net.Listen("tcp", net.JoinHostPort(cfg.ListenAddress, "0"))
	if err != nil {
		return fmt.Errorf("listen on %s: %w", cfg.ListenAddress, err)
	}
	defer listener.Close()

	port := listener.Addr().(*net.TCPAddr).Port
	if err := writePortFile(cfg.PortFile, port); err != nil {
		return err
	}

	server := &http.Server{Handler: proxy}
	serverErr := make(chan error, 1)
	go func() {
		serverErr <- server.Serve(listener)
	}()

	stopCh := watchForShutdown(cfg.StopFile)
	select {
	case <-stopCh:
	case err := <-serverErr:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("serve capture proxy: %w", err)
		}
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	if err := server.Shutdown(ctx); err != nil && !errors.Is(err, context.Canceled) {
		return fmt.Errorf("shutdown capture proxy: %w", err)
	}

	if err := <-serverErr; err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("capture proxy exit: %w", err)
	}

	return nil
}

// parseFlags converts wrapper arguments into the helper runtime options.
func parseFlags(args []string) (options, error) {
	fs := flag.NewFlagSet("dd_topt_ci_visibility_capture", flag.ContinueOnError)
	fs.SetOutput(io.Discard)

	cfg := options{}
	fs.StringVar(&cfg.ListenAddress, "listen-address", defaultListenAddress, "local interface to bind")
	fs.StringVar(&cfg.PortFile, "port-file", "", "file used to publish the chosen listen port")
	fs.StringVar(&cfg.StopFile, "stop-file", "", "sentinel file used to request graceful shutdown")
	fs.StringVar(&cfg.OutputDir, "output-dir", "", "Bazel undeclared outputs directory")
	fs.StringVar(&cfg.UpstreamURL, "upstream-url", defaultUpstreamURL, "original agent URL to proxy to")

	if err := fs.Parse(args); err != nil {
		return options{}, err
	}
	return cfg, nil
}

// validateOptions rejects wrapper invocations that would not be able to publish captured payload files.
func validateOptions(cfg options) error {
	if strings.TrimSpace(cfg.PortFile) == "" {
		return errors.New("port-file is required")
	}
	if strings.TrimSpace(cfg.StopFile) == "" {
		return errors.New("stop-file is required")
	}
	if strings.TrimSpace(cfg.OutputDir) == "" {
		return errors.New("output-dir is required")
	}
	if strings.TrimSpace(cfg.UpstreamURL) == "" {
		return errors.New("upstream-url is required")
	}
	return nil
}

// writePortFile publishes the chosen local port so the wrapper can point the tracer at the helper.
func writePortFile(path string, port int) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create port-file directory: %w", err)
	}
	if err := os.WriteFile(path, []byte(strconv.Itoa(port)), 0o644); err != nil {
		return fmt.Errorf("write port-file %s: %w", path, err)
	}
	return nil
}

// watchForShutdown waits until either the wrapper stop sentinel appears or the process receives a termination signal.
func watchForShutdown(stopFile string) <-chan struct{} {
	done := make(chan struct{})
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)

	go func() {
		defer close(done)
		ticker := time.NewTicker(shutdownPollInterval)
		defer ticker.Stop()
		defer signal.Stop(signals)

		for {
			select {
			case <-signals:
				return
			case <-ticker.C:
				if _, err := os.Stat(stopFile); err == nil {
					return
				}
			}
		}
	}()

	return done
}

// ServeHTTP captures CI Visibility uploads into Bazel outputs and proxies the original request when possible.
func (p *captureProxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	if err := p.captureRequest(r, body); err != nil {
		fmt.Fprintf(os.Stderr, "dd_topt_ci_visibility_capture: capture %s failed: %v\n", r.URL.Path, err)
	}

	resp, err := p.forwardRequest(r, body)
	if err != nil {
		if shouldAckCaptureWithoutProxy(r.URL.Path) {
			w.WriteHeader(http.StatusAccepted)
			return
		}
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	copyResponseHeaders(w.Header(), resp.Header)
	w.WriteHeader(resp.StatusCode)
	if _, copyErr := io.Copy(w, resp.Body); copyErr != nil {
		fmt.Fprintf(os.Stderr, "dd_topt_ci_visibility_capture: copy response body failed: %v\n", copyErr)
	}
}

// captureRequest copies recognized CI Visibility payload requests into the Bazel undeclared outputs tree.
func (p *captureProxy) captureRequest(r *http.Request, body []byte) error {
	switch classifyCaptureRequest(r.URL.Path) {
	case captureRequestTests:
		return p.writeTestPayload(body)
	case captureRequestCoverage:
		return p.writeCoveragePayload(r.Header.Get("Content-Type"), body)
	default:
		return nil
	}
}

// classifyCaptureRequest maps tracer HTTP paths onto Bazel payload directories.
func classifyCaptureRequest(urlPath string) captureRequestKind {
	switch {
	case strings.HasSuffix(urlPath, "/api/v2/citestcycle"):
		return captureRequestTests
	case strings.HasSuffix(urlPath, "/api/v2/citestcov"):
		return captureRequestCoverage
	default:
		return captureRequestNone
	}
}

// shouldAckCaptureWithoutProxy keeps wrapped tests running even when no upstream agent is reachable for replayable payload requests.
func shouldAckCaptureWithoutProxy(urlPath string) bool {
	return classifyCaptureRequest(urlPath) != captureRequestNone
}

// writeTestPayload stores a replayable CI test-cycle request body under payloads/tests.
func (p *captureProxy) writeTestPayload(body []byte) error {
	dir := filepath.Join(p.outputDir, "payloads", "tests")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("create tests payload directory: %w", err)
	}

	index := p.testCount.Add(1)
	path := filepath.Join(dir, fmt.Sprintf("span_events_%020d.msgpack", index))
	if err := os.WriteFile(path, body, 0o644); err != nil {
		return fmt.Errorf("write test payload %s: %w", path, err)
	}
	return nil
}

// writeCoveragePayload extracts the multipart coveragex body and stores it under payloads/coverage.
func (p *captureProxy) writeCoveragePayload(contentType string, body []byte) error {
	payload, extension, err := extractCoveragePart(contentType, body)
	if err != nil {
		return err
	}

	dir := filepath.Join(p.outputDir, "payloads", "coverage")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("create coverage payload directory: %w", err)
	}

	index := p.coverageCount.Add(1)
	path := filepath.Join(dir, fmt.Sprintf("coverage_%020d%s", index, extension))
	if err := os.WriteFile(path, payload, 0o644); err != nil {
		return fmt.Errorf("write coverage payload %s: %w", path, err)
	}
	return nil
}

// extractCoveragePart pulls the multipart coveragex payload out of a tracer upload request.
func extractCoveragePart(contentType string, body []byte) ([]byte, string, error) {
	mediaType, params, err := mime.ParseMediaType(contentType)
	if err != nil {
		return nil, "", fmt.Errorf("parse coverage content type %q: %w", contentType, err)
	}
	if !strings.HasPrefix(mediaType, "multipart/") {
		return nil, "", fmt.Errorf("unexpected coverage content type %q", contentType)
	}

	reader := multipart.NewReader(bytes.NewReader(body), params["boundary"])
	for {
		part, err := reader.NextPart()
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return nil, "", fmt.Errorf("read coverage multipart: %w", err)
		}
		if part.FormName() != "coveragex" {
			continue
		}
		payload, readErr := io.ReadAll(part)
		if readErr != nil {
			return nil, "", fmt.Errorf("read coverage part: %w", readErr)
		}
		return payload, coveragePayloadExtension(part.FileName(), part.Header.Get("Content-Type")), nil
	}

	return nil, "", errors.New("coverage multipart did not contain coveragex")
}

// coveragePayloadExtension chooses the replay file extension that matches the tracer upload content type.
func coveragePayloadExtension(fileName, contentType string) string {
	if strings.HasSuffix(strings.ToLower(fileName), ".msgpack") || strings.Contains(strings.ToLower(contentType), "application/msgpack") {
		return ".msgpack"
	}
	return ".json"
}

// forwardRequest proxies the original tracer request to the configured upstream agent URL.
func (p *captureProxy) forwardRequest(r *http.Request, body []byte) (*http.Response, error) {
	if p.upstream == nil {
		return nil, errors.New("upstream URL is not configured")
	}

	target := *p.upstream
	target.Path = joinURLPath(p.upstream.Path, r.URL.Path)
	target.RawQuery = r.URL.RawQuery

	req, err := http.NewRequestWithContext(r.Context(), r.Method, target.String(), bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("create upstream request: %w", err)
	}
	copyRequestHeaders(req.Header, r.Header)
	return p.client.Do(req)
}

// joinURLPath preserves the incoming tracer request path when the upstream base URL already has a prefix.
func joinURLPath(basePath, requestPath string) string {
	switch {
	case basePath == "":
		return requestPath
	case requestPath == "":
		return basePath
	case strings.HasSuffix(basePath, "/") && strings.HasPrefix(requestPath, "/"):
		return basePath + strings.TrimPrefix(requestPath, "/")
	case strings.HasSuffix(basePath, "/") || strings.HasPrefix(requestPath, "/"):
		return basePath + requestPath
	default:
		return basePath + "/" + requestPath
	}
}

// copyRequestHeaders clones incoming tracer headers onto the upstream proxy request.
func copyRequestHeaders(dst, src http.Header) {
	for key, values := range src {
		dst.Del(key)
		for _, value := range values {
			dst.Add(key, value)
		}
	}
}

// copyResponseHeaders mirrors upstream response headers back to the wrapped tracer request.
func copyResponseHeaders(dst, src http.Header) {
	for key, values := range src {
		dst.Del(key)
		for _, value := range values {
			dst.Add(key, value)
		}
	}
}
