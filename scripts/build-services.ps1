# PowerShell equivalent of build-services.sh
# Serial image build fallback: use when the concurrent `docker compose up --build`
# fails on Gradle file-lock timeouts.

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $RepoRoot
try {
    $services = @(
        'config-server',
        'discovery-server',
        'api-gateway',
        'smartbank-gateway',
        'fraudetect-service',
        'merchant-backoffice'
    )

    foreach ($service in $services) {
        "Building service: $service"
        docker compose build $service
        if ($LASTEXITCODE -ne 0) {
            throw "docker compose build $service failed with exit code $LASTEXITCODE"
        }
    }
}
finally {
    Pop-Location
}
