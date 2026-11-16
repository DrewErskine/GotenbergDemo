<#
.SYNOPSIS
    Gotenberg POC harness for the CM auto-generate-PDF research (INC000011288638).

.DESCRIPTION
    Renders every URL in a list file to PDF using Gotenberg (MIT) and its headless
    Chromium engine. Each PDF is written to output\pages\<last-path-segment>.pdf.

    Can either start a local Gotenberg container (requires Linux-container mode) or
    target an existing dev-tier instance with -SkipContainerStart.

    Does NOT modify the Sitecore stack or any Sitecore configuration.

.PARAMETER UrlListPath
    Text file with one URL per line (blank lines and lines starting with # are ignored).
    Relative paths resolve against the script folder. Default: sample\urls.txt.

.PARAMETER GotenbergUrl
    Base URL of an existing Gotenberg instance. Default http://localhost:3000.

.PARAMETER SkipContainerStart
    Do not start/stop a local container; just use the endpoint at -GotenbergUrl.

.PARAMETER ImageTag
    Pinned Gotenberg image. Keep this explicit - see README section 3 (CVE history).

.PARAMETER KeepRunning
    Leave the local Gotenberg container running after the run finishes.

.EXAMPLE
    .\Test-Gotenberg.ps1
.EXAMPLE
    .\Test-Gotenberg.ps1 -UrlListPath sample\other-urls.txt -KeepRunning
.EXAMPLE
    .\Test-Gotenberg.ps1 -GotenbergUrl "http://gotenberg-dev:3000" -SkipContainerStart
#>
[CmdletBinding()]
param(
    [string]$UrlListPath = "sample\urls.txt",
    [string]$GotenbergUrl = "http://localhost:3000",
    [switch]$SkipContainerStart,
    [string]$ImageTag = "gotenberg/gotenberg:8.34.0",
    [switch]$KeepRunning
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$containerName = 'gotenberg-poc'
$baseUrl       = $GotenbergUrl.TrimEnd('/')
$pagesDir      = Join-Path $PSScriptRoot 'output\pages'

function Write-Step { param($m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "  [PASS] $m" -ForegroundColor Green }
function Write-Fail { param($m) Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-Info { param($m) Write-Host "  $m" -ForegroundColor Gray }
function Write-Warn { param($m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }

# --- Preflight --------------------------------------------------------------------
Write-Step "Preflight"

$listFile = if ([IO.Path]::IsPathRooted($UrlListPath)) { $UrlListPath } else { Join-Path $PSScriptRoot $UrlListPath }
if (-not (Test-Path $listFile)) { Write-Fail "URL list not found: $listFile"; exit 1 }

$urls = @(Get-Content $listFile |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith('#') })
if ($urls.Count -eq 0) { Write-Fail "No URLs found in $listFile"; exit 1 }

New-Item -ItemType Directory -Path $pagesDir -Force | Out-Null

$curl = "$env:SystemRoot\System32\curl.exe"
if (-not (Test-Path $curl)) { Write-Fail "curl.exe not found (expected on Windows 10+)."; exit 1 }

if (-not $SkipContainerStart) {
    try   { $osType = (docker info --format '{{.OSType}}' 2>$null).Trim() }
    catch { Write-Fail "Docker CLI not available. Is Docker Desktop running?"; exit 1 }

    Write-Info "Docker OSType = $osType"

    if ($osType -ne 'linux') {
        Write-Fail "Docker is in '$osType'-container mode. Gotenberg is a Linux-only image."
        Write-Host @"

  Gotenberg cannot start until Docker serves Linux containers. Options:

  OPTION 1 (recommended) - target a dev-tier instance, no local container:
      .\Test-Gotenberg.ps1 -GotenbergUrl "http://<dev-host>:3000" -SkipContainerStart

  OPTION 2 - WSL2 + Docker in WSL (keeps the Sitecore stack running):
      wsl --install -d Ubuntu
      # then run Gotenberg inside Ubuntu, and re-run with -SkipContainerStart

  OPTION 3 - switch Docker to Linux containers (Sitecore KEEPS RUNNING;
             you just can't manage those containers until you switch back):
      & 'C:\Program Files\Docker\Docker\DockerCli.exe' -SwitchLinuxEngine
      cd C:\GotenbergDemo ; .\Test-Gotenberg.ps1
      & 'C:\Program Files\Docker\Docker\DockerCli.exe' -SwitchWindowsEngine

  See README.md section 2.
"@ -ForegroundColor Yellow
        exit 1
    }

    if ($ImageTag -match ':8$' -or $ImageTag -match ':latest$') {
        Write-Warn "Floating tag '$ImageTag'. Pin a patched version for anything beyond a throwaway test (README section 3)."
    }
}
Write-Ok "Preflight checks passed ($($urls.Count) URL(s) from $listFile)"

# --- Start Gotenberg --------------------------------------------------------------
if (-not $SkipContainerStart) {
    Write-Step "Starting Gotenberg ($ImageTag)"

    $existing = docker ps -aq --filter "name=^/$containerName$" 2>$null
    if ($existing) { Write-Info "Removing previous '$containerName'"; docker rm -f $containerName | Out-Null }

    Write-Info "Pulling image (first run downloads several hundred MB)"
    docker pull $ImageTag | Out-Null

    docker run -d --name $containerName -p 3000:3000 $ImageTag | Out-Null
}

# --- Health ------------------------------------------------------------------------
Write-Step "Health check"
Write-Info "Waiting for $baseUrl/health"

$healthy = $false
foreach ($i in 1..30) {
    try {
        if ((Invoke-WebRequest "$baseUrl/health" -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200) {
            $healthy = $true; break
        }
    } catch { }
    Start-Sleep -Seconds 2
}
if (-not $healthy) {
    Write-Fail "Gotenberg not healthy at $baseUrl"
    if (-not $SkipContainerStart) { docker logs $containerName --tail 40 }
    exit 1
}
Write-Ok "Gotenberg healthy at $baseUrl"

# --- Helper ------------------------------------------------------------------------
function Invoke-Conversion {
    param([string]$Name, [string[]]$CurlArgs, [string]$OutFile)

    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $curl @CurlArgs --silent --show-error --fail -o $OutFile 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $sw.Stop()

    if ($code -ne 0 -or -not (Test-Path $OutFile)) {
        Write-Fail "$Name (curl exit $code)"; return $false
    }

    $size = (Get-Item $OutFile).Length
    if ($size -lt 4) { Write-Fail "$Name - output too small ($size bytes)"; return $false }

    $head  = [IO.File]::ReadAllBytes($OutFile)[0..3]
    $magic = -join ($head | ForEach-Object { [char]$_ })
    if ($magic -ne '%PDF') { Write-Fail "$Name - not a PDF (header '$magic')"; return $false }

    Write-Ok ("{0} -> {1} ({2:N0} KB, {3:N1}s)" -f $Name, (Split-Path $OutFile -Leaf), ($size/1KB), $sw.Elapsed.TotalSeconds)
    return $true
}

# --- Render each URL -----------------------------------------------------------------
Write-Step "URL list to PDFs"

$results   = [ordered]@{}
$usedNames = @{}

# CSS injected into every page before printing. Keeps images and figures from being split
# across a page break (the "squashed image" problem). Add the site's card class here if cards
# still split, e.g. ".promo-card".
$printFixCss = "img, figure, picture, li, tr { break-inside: avoid; page-break-inside: avoid; }"

# Lazy-load fix, source: https://github.com/gotenberg/gotenberg/discussions/1580
# Strips loading="lazy", injects $printFixCss once, then waits until every image has loaded.
$lazyImageExpression = "(() => { if (!document.getElementById('pdf-print-fix')) { var s = document.createElement('style'); s.id = 'pdf-print-fix'; s.textContent = '$printFixCss'; document.head.appendChild(s); } document.querySelectorAll('img[loading]').forEach(i => i.removeAttribute('loading')); return [...document.images].every(i => i.complete); })()"

# Page size. Chromium lays the page out at the printable paper width, so Letter (about 740 CSS px
# after margins) triggers the site's tablet/mobile breakpoint and stacks side-by-side items.
# A wide custom page makes it lay out as on a desktop. Height is roughly A4 proportions.
$paperWidth  = '1280px'
$paperHeight = '1810px'

foreach ($u in $urls) {
    try { $uri = [Uri]$u; if (-not $uri.IsAbsoluteUri) { throw "relative" } }
    catch { Write-Fail "Invalid URL: $u"; $results[$u] = $false; continue }

    # Name = last non-empty path segment (no extension); host name if the path is empty.
    $seg = [Uri]::UnescapeDataString($uri.AbsolutePath).TrimEnd('/').Split('/')[-1]
    $seg = $seg -replace '\.(html?|aspx?|php)$', ''
    if (-not $seg) { $seg = $uri.Host }
    $name = ($seg -replace '[^\w\-\.]+', '-').Trim('-')
    if (-not $name) { $name = 'page' }

    # Two URLs can share a last segment; keep both by numbering the repeats.
    if ($usedNames.ContainsKey($name)) { $usedNames[$name]++; $name = "$name-$($usedNames[$name])" }
    else { $usedNames[$name] = 1 }

    $results[$u] = Invoke-Conversion -Name $u -OutFile (Join-Path $pagesDir "$name.pdf") -CurlArgs @(
        '--request','POST',"$baseUrl/forms/chromium/convert/url",
        '--form',"url=$u",
        '--form','emulatedMediaType=print',
        '--form','printBackground=true',
        '--form','generateTaggedPdf=true',
        '--form',"paperWidth=$paperWidth",
        '--form',"paperHeight=$paperHeight",
        # Lazy-loaded images and page-break CSS (see $lazyImageExpression above).
        # --form-string (not --form) because the expression contains ';'.
        '--form-string',"waitForExpression=$lazyImageExpression",
        '--form','waitDelay=2s'
    )
}

# --- Summary -------------------------------------------------------------------------
Write-Step "Summary"
foreach ($k in $results.Keys) {
    if ($results[$k]) { Write-Ok $k } else { Write-Fail $k }
}
Write-Info "Output folder: $pagesDir"

if (-not $SkipContainerStart) {
    if ($KeepRunning) {
        Write-Info "Container left running. Stop with: docker rm -f $containerName"
    } else {
        docker rm -f $containerName | Out-Null
        Write-Info "Container '$containerName' removed."
    }
}

if ($results.Values -contains $false) { exit 1 } else { exit 0 }
