# PowerShell equivalent of easypay.sh
# Runs easypay-service on the host (port 8081), instrumented with the Grafana
# OpenTelemetry Java distribution, exporting OTLP to the collector on localhost.
#
# Prerequisites:
#   .\scripts\download-grafana-agent.ps1
#   .\gradlew.bat :easypay-service:build

$ErrorActionPreference = 'Stop'

$RepoRoot = $PSScriptRoot

$env:OTEL_SERVICE_NAME = 'easypay-service'
$env:OTEL_EXPORTER_OTLP_ENDPOINT = 'http://localhost:4317'
$env:OTEL_EXPORTER_OTLP_PROTOCOL = 'grpc'
$env:OTEL_RESOURCE_ATTRIBUTES = 'source=agent'

$env:SERVER_PORT = '8081'
$env:LOGS_DIRECTORY = Join-Path $RepoRoot 'logs'
New-Item -ItemType Directory -Force -Path $env:LOGS_DIRECTORY | Out-Null

$Agent = Join-Path $RepoRoot 'instrumentation\grafana-opentelemetry-java.jar'
$Jar = Join-Path $RepoRoot 'easypay-service\build\libs\easypay-service-0.0.1-SNAPSHOT.jar'

if (-not (Test-Path $Agent)) {
    throw "Agent not found at $Agent - run .\scripts\download-grafana-agent.ps1 first"
}
if (-not (Test-Path $Jar)) {
    throw "Jar not found at $Jar - run .\gradlew.bat :easypay-service:build first"
}

& java -Xms512m -Xmx512m "-javaagent:$Agent" -jar $Jar @args
