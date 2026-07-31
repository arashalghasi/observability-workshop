# PowerShell equivalent of download-grafana-agent.sh
# Downloads the Grafana OpenTelemetry Java distribution into ../instrumentation

$ErrorActionPreference = 'Stop'

$Version = 'v2.4.0-beta.1'

$AgentUrl = "https://github.com/grafana/grafana-opentelemetry-java/releases/download/$Version/grafana-opentelemetry-java.jar"

$InstrumentationDir = Join-Path $PSScriptRoot '..\instrumentation'
New-Item -ItemType Directory -Force -Path $InstrumentationDir | Out-Null
$InstrumentationDir = (Resolve-Path $InstrumentationDir).Path

$Target = Join-Path $InstrumentationDir 'grafana-opentelemetry-java.jar'

$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri $AgentUrl -OutFile $Target -UseBasicParsing

"Grafana OpenTelemetry agent downloaded successfully in $InstrumentationDir"
