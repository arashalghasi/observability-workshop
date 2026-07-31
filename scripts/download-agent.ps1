# PowerShell equivalent of download-agent.sh
# Downloads the OpenTelemetry Java agent into ../instrumentation

$ErrorActionPreference = 'Stop'

$Version = 'v2.11.0'

$AgentUrl = "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/$Version/opentelemetry-javaagent.jar"

$InstrumentationDir = Join-Path $PSScriptRoot '..\instrumentation'
New-Item -ItemType Directory -Force -Path $InstrumentationDir | Out-Null
$InstrumentationDir = (Resolve-Path $InstrumentationDir).Path

$Target = Join-Path $InstrumentationDir 'opentelemetry-javaagent.jar'

# Invoke-WebRequest's progress bar cripples throughput on large files
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri $AgentUrl -OutFile $Target -UseBasicParsing

"OpenTelemetry Java agent downloaded successfully in $InstrumentationDir"
