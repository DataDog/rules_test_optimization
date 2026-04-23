package main

import (
	"bytes"
	"mime/multipart"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"testing"
)

// TestClassifyCaptureRequest verifies that CI Visibility endpoints map to the expected Bazel payload directories.
func TestClassifyCaptureRequest(t *testing.T) {
	t.Parallel()

	for _, tc := range []struct {
		name string
		path string
		want captureRequestKind
	}{
		{name: "test cycle", path: "/evp_proxy/v2/api/v2/citestcycle", want: captureRequestTests},
		{name: "coverage", path: "/evp_proxy/v2/api/v2/citestcov", want: captureRequestCoverage},
		{name: "other", path: "/info", want: captureRequestNone},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := classifyCaptureRequest(tc.path); got != tc.want {
				t.Fatalf("classifyCaptureRequest(%q) = %v, want %v", tc.path, got, tc.want)
			}
		})
	}
}

// TestWriteTestPayload verifies that test-cycle uploads land under payloads/tests with replayable file names.
func TestWriteTestPayload(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	proxy := &captureProxy{outputDir: root}
	body := []byte("test-cycle-payload")

	if err := proxy.writeTestPayload(body); err != nil {
		t.Fatalf("writeTestPayload: %v", err)
	}

	matches, err := filepath.Glob(filepath.Join(root, "payloads", "tests", "span_events_*.msgpack"))
	if err != nil {
		t.Fatalf("glob test payloads: %v", err)
	}
	if len(matches) != 1 {
		t.Fatalf("expected 1 test payload, found %d", len(matches))
	}

	got, err := os.ReadFile(matches[0])
	if err != nil {
		t.Fatalf("read test payload: %v", err)
	}
	if !bytes.Equal(got, body) {
		t.Fatalf("test payload = %q, want %q", got, body)
	}
}

// TestExtractCoveragePart verifies that multipart coverage uploads preserve the tracer payload bytes and extension.
func TestExtractCoveragePart(t *testing.T) {
	t.Parallel()

	var requestBody bytes.Buffer
	writer := multipart.NewWriter(&requestBody)

	eventPart, err := writer.CreateFormFile("event", "fileevent.json")
	if err != nil {
		t.Fatalf("CreateFormFile(event): %v", err)
	}
	if _, err := eventPart.Write([]byte(`{"dummy":true}`)); err != nil {
		t.Fatalf("write event part: %v", err)
	}

	coveragePart, err := writer.CreateFormFile("coveragex", "filecoveragex.msgpack")
	if err != nil {
		t.Fatalf("CreateFormFile(coveragex): %v", err)
	}
	want := []byte("coverage-payload")
	if _, err := coveragePart.Write(want); err != nil {
		t.Fatalf("write coverage part: %v", err)
	}

	if err := writer.Close(); err != nil {
		t.Fatalf("Close writer: %v", err)
	}

	got, extension, err := extractCoveragePart(writer.FormDataContentType(), requestBody.Bytes())
	if err != nil {
		t.Fatalf("extractCoveragePart: %v", err)
	}
	if extension != ".msgpack" {
		t.Fatalf("coverage extension = %q, want .msgpack", extension)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("coverage payload = %q, want %q", got, want)
	}
}

// TestForwardRequestPreservesPath verifies that proxy requests keep the tracer request path when the upstream has no base path.
func TestForwardRequestPreservesPath(t *testing.T) {
	t.Parallel()

	server := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/evp_proxy/v2/api/v2/citestcycle" {
			t.Fatalf("upstream path = %q, want /evp_proxy/v2/api/v2/citestcycle", r.URL.Path)
		}
		w.WriteHeader(http.StatusAccepted)
	})

	testServer := &http.Server{Handler: server}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Listen: %v", err)
	}
	defer listener.Close()
	go func() {
		_ = testServer.Serve(listener)
	}()
	defer func() {
		_ = testServer.Close()
	}()

	proxy := &captureProxy{
		upstream: mustParseURL("http://" + listener.Addr().String()),
		client:   &http.Client{},
	}

	req, err := http.NewRequest(http.MethodPost, "http://capture.invalid/evp_proxy/v2/api/v2/citestcycle", bytes.NewReader([]byte("payload")))
	if err != nil {
		t.Fatalf("NewRequest: %v", err)
	}

	resp, err := proxy.forwardRequest(req, []byte("payload"))
	if err != nil {
		t.Fatalf("forwardRequest: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusAccepted)
	}
}

// mustParseURL converts a constant test URL into a parsed *url.URL.
func mustParseURL(raw string) *url.URL {
	parsed, err := url.Parse(raw)
	if err != nil {
		panic(err)
	}
	return parsed
}
