# A Starlark test rule that uploads CI Visibility test and coverage payloads
# within the same `bazel test` invocation by watching a shared writable
# payloads directory for quiescence, enriching test payloads with Git
# metadata, and sending them to Datadog.
#
# Usage pattern for best results:
# - Configure tests to write payloads under an external writable directory
#   exposed via `--sandbox_writable_path` and made available to tests via
#   `--test_env=DD_PAYLOADS_DIR=/abs/path/.testoptimization/payloads`.
# - Invoke this test target together with your tests (e.g., include in a
#   test_suite or add to the same invocation). It runs outside the sandbox and
#   uploads after the directory is quiescent.

def _uploader_impl(ctx):
    payloads_dir = ctx.attr.payloads_dir
    tests_subdir = ctx.attr.tests_subdir
    coverage_subdir = ctx.attr.coverage_subdir
    quiescent_sec = ctx.attr.quiescent_sec
    max_wait_sec = ctx.attr.max_wait_sec
    fail_on_error = ctx.attr.fail_on_error
    debug = ctx.attr.debug

    # Bash implementation (Unix)
    bash_script = """
#!/usr/bin/env bash
set -euo pipefail

PAYLOADS_DIR="${{DD_PAYLOADS_DIR:-{payloads_dir}}}"
TESTS_SUBDIR="{tests_subdir}"
COVERAGE_SUBDIR="{coverage_subdir}"
QUIESCENT_SEC={quiescent_sec}
MAX_WAIT_SEC={max_wait_sec}
FAIL_ON_ERROR={fail_on_error}

log() {{ echo "[dd-uploader] $1"; }}
dbg() {{ if [[ {debug} == 1 ]]; then echo "[dd-uploader][dbg] $1"; fi }}

if [[ "$(uname -s | tr 'A-Z' 'a-z')" == *mingw* || "$(uname -s | tr 'A-Z' 'a-z')" == *msys* || "$(uname -s | tr 'A-Z' 'a-z')" == *cygwin* ]]; then
  exec powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$0.ps1"
fi

if [[ ! -d "$PAYLOADS_DIR" ]]; then
  log "payloads dir not found: $PAYLOADS_DIR (nothing to upload)"
  exit 0
fi

latest_mtime() {{
  local d="$1"
  if [[ ! -d "$d" ]]; then echo 0; return; fi
  local mt
  mt=$(find "$d" -type f -printf '%T@\n' 2>/dev/null | sort -nr | head -1 || true)
  if [[ -z "$mt" ]]; then echo 0; else printf '%.0f' "$mt"; fi
}}

start_ts=$(date +%s)
last_ts=$(latest_mtime "$PAYLOADS_DIR")
dbg "initial latest mtime: $last_ts"
while true; do
  now=$(date +%s)
  elapsed=$(( now - start_ts ))
  if (( elapsed > MAX_WAIT_SEC )); then
    log "max wait exceeded ($MAX_WAIT_SEC s); proceeding to upload"
    break
  fi
  cur=$(latest_mtime "$PAYLOADS_DIR")
  if (( cur == 0 )); then
    dbg "no files yet; sleeping"
    sleep 2
    continue
  fi
  idle=$(( now - cur ))
  if (( idle >= QUIESCENT_SEC )); then
    log "directory quiescent for $idle s; starting upload"
    break
  fi
  sleep 2
done

# Build endpoints
DD_SITE="${{DD_SITE:-datadoghq.com}}"
if [[ -z "${{DD_TRACE_AGENT_URL:-}}" ]]; then
  AGENTLESS=1
  TEST_URL="https://citestcycle-intake.${{DD_SITE}}/api/v2/citestcycle"
  COV_URL="https://citestcov-intake.${{DD_SITE}}/api/v2/citestcov"
else
  AGENTLESS=0
  TEST_URL="${{DD_TRACE_AGENT_URL}}/evp_proxy/v2/api/v2/citestcycle"
  COV_URL="${{DD_TRACE_AGENT_URL}}/evp_proxy/v2/api/v2/citestcov"
fi

hdrs=(
  -H "Datadog-Meta-Lang: bazel-starlark"
  -H "Datadog-Meta-Lang-Version: n/a"
  -H "Datadog-Meta-Lang-Interpreter: bazel-test"
  -H "Datadog-Meta-Tracer-Version: 1.0.0"
  -H "Accept: application/json"
)
if (( AGENTLESS == 1 )); then
  if [[ -z "${{DD_API_KEY:-}}" ]]; then
    log "DD_API_KEY required for agentless uploads; skipping"
    exit 0
  fi
  hdrs+=( -H "DD-API-KEY: $DD_API_KEY" )
else
  # EVP subdomain headers per endpoint
  TEST_EVP=( -H "X-Datadog-EVP-Subdomain: citestcycle-intake" )
  COV_EVP=( -H "X-Datadog-EVP-Subdomain: citestcov-intake" )
fi

# Git metadata from env (populated by wrapper). Optional.
REPO_URL="${{DD_GIT_REPOSITORY_URL:-}}"
BRANCH="${{DD_GIT_BRANCH:-}}"
SHA="${{DD_GIT_COMMIT_SHA:-}}"
HEAD_SHA="${{DD_GIT_HEAD_COMMIT:-}}"
COMMIT_MSG="${{DD_GIT_COMMIT_MESSAGE:-}}"
HEAD_MSG="${{DD_GIT_HEAD_MESSAGE:-}}"
ENV_NAME="${{DD_ENV:-CI}}"
SERVICE="${{DD_SERVICE:-unnamed-service}}"

merge_with_jq() {{
  local infile="$1"; local tmpfile="$2"
  if ! command -v jq >/dev/null 2>&1; then
    # No jq; send as-is
    cp "$infile" "$tmpfile"
    return 0
  fi
  jq --arg repo "$REPO_URL" \
     --arg br "$BRANCH" \
     --arg sha "$SHA" \
     --arg hsha "$HEAD_SHA" \
     --arg msg "$COMMIT_MSG" \
     --arg hmsg "$HEAD_MSG" \
     --arg env "$ENV_NAME" \
     --arg svc "$SERVICE" \
     '(.metadata["*"] |= ((. // {{}}) + {
        "git.repository_url": $repo,
        "git.branch": $br,
        "git.commit.sha": $sha,
        "git.commit.head.sha": $hsha,
        "git.commit.message": $msg,
        "git.commit.head.message": $hmsg,
        "env": $env,
        "service.name": $svc
      }))' "$infile" > "$tmpfile"
}}

upload_tests() {{
  local d="$PAYLOADS_DIR/$TESTS_SUBDIR"
  [[ -d "$d" ]] || return 0
  shopt -s nullglob
  for f in "$d"/*.json; do
    local body
    body="${f}.enriched.json"
    merge_with_jq "$f" "$body"
    if (( AGENTLESS == 1 )); then
      curl -f -sS --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 --retry-connrefused \
        -X POST "${TEST_URL}" "${hdrs[@]}" -H "Content-Type: application/json" --data-binary @"${body}" -o /dev/null -w "%{http_code}" >/dev/null || {{
          if (( FAIL_ON_ERROR )); then log "upload failed: $f"; exit 1; else log "upload failed (ignored): $f"; fi
        }}
    else
      curl -f -sS --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 --retry-connrefused \
        -X POST "${TEST_URL}" "${hdrs[@]}" "${TEST_EVP[@]}" -H "Content-Type: application/json" --data-binary @"${body}" -o /dev/null -w "%{http_code}" >/dev/null || {{
          if (( FAIL_ON_ERROR )); then log "upload failed: $f"; exit 1; else log "upload failed (ignored): $f"; fi
        }}
    fi
    log "uploaded test payload: $f"
  done
}}

upload_coverage() {{
  local d="$PAYLOADS_DIR/$COVERAGE_SUBDIR"
  [[ -d "$d" ]] || return 0
  local eventjson
  eventjson="${d}/event.json"
  echo '{"dummy":true}' > "$eventjson"
  shopt -s nullglob
  for f in "$d"/*.json; do
    if (( AGENTLESS == 1 )); then
      curl -f -sS --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 --retry-connrefused \
        -X POST "${COV_URL}" "${hdrs[@]}" \
        -F "event=@${eventjson};type=application/json;filename=fileevent.json" \
        -F "coveragex=@${f};type=application/json;filename=filecoveragex.json" -o /dev/null -w "%{http_code}" >/dev/null || {{
          if (( FAIL_ON_ERROR )); then log "coverage upload failed: $f"; exit 1; else log "coverage upload failed (ignored): $f"; fi
        }}
    else
      curl -f -sS --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 --retry-connrefused \
        -X POST "${COV_URL}" "${hdrs[@]}" "${COV_EVP[@]}" \
        -F "event=@${eventjson};type=application/json;filename=fileevent.json" \
        -F "coveragex=@${f};type=application/json;filename=filecoveragex.json" -o /dev/null -w "%{http_code}" >/dev/null || {{
          if (( FAIL_ON_ERROR )); then log "coverage upload failed: $f"; exit 1; else log "coverage upload failed (ignored): $f"; fi
        }}
    fi
    log "uploaded coverage payload: $f"
  done
}}

upload_tests
upload_coverage
log "done"
""".format(
        payloads_dir = payloads_dir,
        tests_subdir = tests_subdir,
        coverage_subdir = coverage_subdir,
        quiescent_sec = quiescent_sec,
        max_wait_sec = max_wait_sec,
        fail_on_error = 1 if fail_on_error else 0,
        debug = 1 if debug else 0,
    )

    # PowerShell implementation (Windows)
    ps_script = """
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$PayloadsDir = if ([string]::IsNullOrEmpty('{payloads_dir}')) { $env:DD_PAYLOADS_DIR } else { '{payloads_dir}' }
$TestsSubdir = '{tests_subdir}'
$CoverageSubdir = '{coverage_subdir}'
$QuiescentSec = {quiescent_sec}
$MaxWaitSec = {max_wait_sec}
$FailOnError = {fail_on_error}

function Log([string]$msg) {{ Write-Output "[dd-uploader] $msg" }}
function Dbg([string]$msg) {{ if ({debug}) {{ Write-Output "[dd-uploader][dbg] $msg" }} }}

if (-not (Test-Path -LiteralPath $PayloadsDir)) {{ Log "payloads dir not found: $PayloadsDir"; exit 0 }}

function Get-LatestMTime([string]$dir) {{
  if (-not (Test-Path -LiteralPath $dir)) {{ return 0 }}
  $files = Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue
  if (-not $files) {{ return 0 }}
  return ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime.ToFileTimeUtc()
}}

$start = Get-Date
while ($true) {{
  $elapsed = ((Get-Date) - $start).TotalSeconds
  if ($elapsed -gt $MaxWaitSec) {{ Log "max wait exceeded ($MaxWaitSec s); proceeding"; break }}
  $files = Get-ChildItem -LiteralPath $PayloadsDir -Recurse -File -ErrorAction SilentlyContinue
  if (-not $files) {{ Start-Sleep -Seconds 2; continue }}
  $latest = ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
  $idle = ((Get-Date) - $latest).TotalSeconds
  if ($idle -ge $QuiescentSec) {{ Log "directory quiescent for $idle s; starting upload"; break }}
  Start-Sleep -Seconds 2
}}

$Agentless = [string]::IsNullOrEmpty($env:DD_TRACE_AGENT_URL)
$DD_Site = if ([string]::IsNullOrEmpty($env:DD_SITE)) {{ 'datadoghq.com' }} else {{ $env:DD_SITE }}
if ($Agentless) {{
  $TestUrl = "https://citestcycle-intake.$DD_Site/api/v2/citestcycle"
  $CovUrl = "https://citestcov-intake.$DD_Site/api/v2/citestcov"
}} else {{
  $TestUrl = "$($env:DD_TRACE_AGENT_URL)/evp_proxy/v2/api/v2/citestcycle"
  $CovUrl = "$($env:DD_TRACE_AGENT_URL)/evp_proxy/v2/api/v2/citestcov"
}}

$CommonHeaders = @{{
  'Datadog-Meta-Lang' = 'bazel-starlark'
  'Datadog-Meta-Lang-Version' = 'n/a'
  'Datadog-Meta-Lang-Interpreter' = 'bazel-test'
  'Datadog-Meta-Tracer-Version' = '1.0.0'
}}
if ($Agentless) {{
  if ([string]::IsNullOrEmpty($env:DD_API_KEY)) {{ Log "DD_API_KEY required for agentless uploads"; exit 0 }}
  $CommonHeaders['DD-API-KEY'] = $env:DD_API_KEY
}} else {{
  $TestEvp = @{{ 'X-Datadog-EVP-Subdomain' = 'citestcycle-intake' }}
  $CovEvp  = @{{ 'X-Datadog-EVP-Subdomain' = 'citestcov-intake' }}
}}

# Git metadata (from env)
$repo = $env:DD_GIT_REPOSITORY_URL
$branch = $env:DD_GIT_BRANCH
$sha = $env:DD_GIT_COMMIT_SHA
$hsha = $env:DD_GIT_HEAD_COMMIT
$msg = $env:DD_GIT_COMMIT_MESSAGE
$hmsg = $env:DD_GIT_HEAD_MESSAGE
$envname = if ([string]::IsNullOrEmpty($env:DD_ENV)) {{ 'CI' }} else {{ $env:DD_ENV }}
$service = if ([string]::IsNullOrEmpty($env:DD_SERVICE)) {{ 'unnamed-service' }} else {{ $env:DD_SERVICE }}

function Merge-GitMeta([string]$infile, [string]$outfile) {{
  try {{
    $obj = Get-Content -LiteralPath $infile -Raw | ConvertFrom-Json -ErrorAction Stop
  }} catch {{ Copy-Item -LiteralPath $infile -Destination $outfile -Force; return }}
  if (-not $obj.metadata) {{ $obj | Add-Member -NotePropertyName metadata -NotePropertyValue @{{}} }}
  if (-not $obj.metadata.'*') {{ $obj.metadata.'*' = @{{}} }}
  $obj.metadata.'*'.'git.repository_url' = $repo
  $obj.metadata.'*'.'git.branch' = $branch
  $obj.metadata.'*'.'git.commit.sha' = $sha
  $obj.metadata.'*'.'git.commit.head.sha' = $hsha
  $obj.metadata.'*'.'git.commit.message' = $msg
  $obj.metadata.'*'.'git.commit.head.message' = $hmsg
  $obj.metadata.'*'.'env' = $envname
  $obj.metadata.'*'.'service.name' = $service
  $obj | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $outfile -Encoding UTF8
}}

function Send-PostJson([string]$url, [hashtable]$headers, [string]$file) {{
  $client = New-Object System.Net.Http.HttpClient
  foreach ($k in $headers.Keys) {{ $client.DefaultRequestHeaders.Add($k, [string]$headers[$k]) }}
  $content = New-Object System.Net.Http.StringContent([IO.File]::ReadAllText($file))
  $content.Headers.ContentType = 'application/json'
  $resp = $client.PostAsync($url, $content).GetAwaiter().GetResult()
  if (-not $resp.IsSuccessStatusCode) {{
    $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if ($FailOnError) {{ throw "HTTP $([int]$resp.StatusCode): $body" }} else {{ Log "upload failed (ignored): HTTP $([int]$resp.StatusCode) $body" }}
  }} else {{ Log "uploaded" }}
}}

# Upload tests
$testDir = Join-Path $PayloadsDir $TestsSubdir
if (Test-Path -LiteralPath $testDir) {{
  Get-ChildItem -LiteralPath $testDir -Filter *.json -File -ErrorAction SilentlyContinue | ForEach-Object {{
    $f = $_.FullName
    $body = "$f.enriched.json"
    Merge-GitMeta $f $body
    $hdrs = $CommonHeaders.Clone()
    if (-not $Agentless) {{ $hdrs['X-Datadog-EVP-Subdomain'] = 'citestcycle-intake' }}
    Send-PostJson $TestUrl $hdrs $body
  }}
}}

# Upload coverage (multipart)
$covDir = Join-Path $PayloadsDir $CoverageSubdir
if (Test-Path -LiteralPath $covDir) {{
  $client = New-Object System.Net.Http.HttpClient
  foreach ($k in $CommonHeaders.Keys) {{ $client.DefaultRequestHeaders.Add($k, [string]$CommonHeaders[$k]) }}
  if (-not $Agentless) {{ $client.DefaultRequestHeaders.Add('X-Datadog-EVP-Subdomain','citestcov-intake') }}
  $eventFile = Join-Path $covDir 'event.json'
  Set-Content -LiteralPath $eventFile -Value '{"dummy":true}' -Encoding UTF8
  Get-ChildItem -LiteralPath $covDir -Filter *.json -File -ErrorAction SilentlyContinue | ForEach-Object {{
    $f = $_.FullName
    $content = New-Object System.Net.Http.MultipartFormDataContent
    $eventContent = New-Object System.Net.Http.StringContent([IO.File]::ReadAllText($eventFile))
    $eventContent.Headers.ContentType = 'application/json'
    $content.Add($eventContent, 'event', 'fileevent.json')
    $fs = [System.IO.File]::OpenRead($f)
    $covContent = New-Object System.Net.Http.StreamContent($fs)
    $covContent.Headers.ContentType = 'application/json'
    $content.Add($covContent, 'coveragex', 'filecoveragex.json')
    $resp = $client.PostAsync($CovUrl, $content).GetAwaiter().GetResult()
    if (-not $resp.IsSuccessStatusCode) {{
      $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      if ($FailOnError) {{ throw "HTTP $([int]$resp.StatusCode): $body" }} else {{ Log "coverage upload failed (ignored): HTTP $([int]$resp.StatusCode) $body" }}
    }} else {{ Log "uploaded coverage: $f" }}
  }}
}}

Log "done"
""".format(
        payloads_dir = payloads_dir.replace("'", "''"),
        tests_subdir = tests_subdir.replace("'", "''"),
        coverage_subdir = coverage_subdir.replace("'", "''"),
        quiescent_sec = quiescent_sec,
        max_wait_sec = max_wait_sec,
        fail_on_error = "$true" if fail_on_error else "$false",
        debug = "$true" if debug else "$false",
    )

    # Emit scripts
    bash_file = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(output = bash_file, content = bash_script, is_executable = True)
    ps_file = ctx.actions.declare_file(ctx.label.name + ".ps1")
    ctx.actions.write(output = ps_file, content = ps_script, is_executable = False)

    runfiles = ctx.runfiles(files = [ps_file])
    return [DefaultInfo(executable = bash_file, runfiles = runfiles)]

dd_payload_uploader = rule(
    implementation = _uploader_impl,
    test = True,
    attrs = {
        "payloads_dir": attr.string(),
        "tests_subdir": attr.string(default = "tests"),
        "coverage_subdir": attr.string(default = "coverage"),
        "quiescent_sec": attr.int(default = 10),
        "max_wait_sec": attr.int(default = 1800),
        "fail_on_error": attr.bool(default = False),
        "debug": attr.bool(default = False),
    },
)


