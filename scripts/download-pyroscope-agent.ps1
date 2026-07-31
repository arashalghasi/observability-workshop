# PowerShell equivalent of download-pyroscope-agent.sh
# Downloads the Pyroscope agent and its OTel bridge into ../instrumentation

$ErrorActionPreference = 'Stop'

$PyroscopeVersion = 'v0.17.0'
$PyroscopeOtelVersion = '0.11.0'

$PyroscopeUrl = "https://github.com/grafana/pyroscope-java/releases/download/$PyroscopeVersion/pyroscope.jar"
$PyroscopeOtelUrl = "https://github.com/grafana/otel-profiling-java/releases/download/v$PyroscopeOtelVersion/pyroscope-otel.jar"

$InstrumentationDir = Join-Path $PSScriptRoot '..\instrumentation'
New-Item -ItemType Directory -Force -Path $InstrumentationDir | Out-Null
$InstrumentationDir = (Resolve-Path $InstrumentationDir).Path

$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri $PyroscopeUrl -OutFile (Join-Path $InstrumentationDir 'pyroscope.jar') -UseBasicParsing
Invoke-WebRequest -Uri $PyroscopeOtelUrl -OutFile (Join-Path $InstrumentationDir 'pyroscope-otel.jar') -UseBasicParsing

"Grafana Pyroscope agent downloaded successfully in $InstrumentationDir"
