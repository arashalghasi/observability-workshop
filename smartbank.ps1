# PowerShell equivalent of smartbank.sh
# Runs smartbank-gateway on the host, instrumented with the Grafana
# OpenTelemetry Java distribution, exporting OTLP to the collector on localhost.
#
# Prerequisites:
#   .\scripts\download-grafana-agent.ps1
#   .\gradlew.bat :smartbank-gateway:build

$ErrorActionPreference = 'Stop'

$RepoRoot = $PSScriptRoot

$env:OTEL_SERVICE_NAME = 'smartbank-gateway'
$env:OTEL_EXPORTER_OTLP_ENDPOINT = 'http://localhost:4317'
$env:OTEL_EXPORTER_OTLP_PROTOCOL = 'grpc'
$env:OTEL_RESOURCE_ATTRIBUTES = 'source=agent'

$env:LOGS_DIRECTORY = Join-Path $RepoRoot 'logs'
New-Item -ItemType Directory -Force -Path $env:LOGS_DIRECTORY | Out-Null

$Agent = Join-Path $RepoRoot 'instrumentation\grafana-opentelemetry-java.jar'
$Jar = Join-Path $RepoRoot 'smartbank-gateway\build\libs\smartbank-gateway-0.0.1-SNAPSHOT.jar'

if (-not (Test-Path $Agent)) {
    throw "Agent not found at $Agent - run .\scripts\download-grafana-agent.ps1 first"
}
if (-not (Test-Path $Jar)) {
    throw "Jar not found at $Jar - run .\gradlew.bat :smartbank-gateway:build first"
}

& java -Xms512m -Xmx512m "-javaagent:$Agent" -jar $Jar @args
