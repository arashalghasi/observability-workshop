# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A hands-on **observability workshop** (published to https://worldline.github.io/observability-workshop/). It has two coupled deliverables:

1. **A Spring Boot microservice payment platform** ("easypay") used as the demo application, plus a Grafana-stack observability backend, all wired with Docker Compose.
2. **The workshop instructions** in `docs/`, which walk attendees through *adding* observability to that application step by step.

Consequence: parts of the application are **deliberately unfinished or broken**. See [Workshop invariants](#workshop-invariants--do-not-fix-these) before changing application code — several "bugs" are the teaching material.

## Commands

### Build

No root `build.gradle.kts` — each module carries its own and is a standalone Spring Boot project — but `settings.gradle.kts` does `include(...)` all seven (`api-gateway`, `config-server`, `discovery-server`, `easypay-service`, `fraudetect-service`, `merchant-backoffice`, `smartbank-gateway`), which is what makes `:module:task` work from the root. Versions are centralized in `gradle/libs.versions.toml`. Java 21, Gradle 8.7 wrapper.

```bash
./gradlew build --parallel -x test     # what devcontainer/CI-adjacent setup uses
./gradlew :easypay-service:build       # single module
```

### Test

```bash
./gradlew test
./gradlew :easypay-service:test
./gradlew :easypay-service:test --tests "com.worldline.easypay.easypayservice.EasypayServiceApplicationTests"
```

Tests are JUnit 5 (`useJUnitPlatform()`); each module has a single context-load smoke test. Docker image builds run `-x test`, so a broken test does not block `docker compose build`.

### Run the stack

```bash
bash scripts/download-agent.sh                        # OTel Java agent -> instrumentation/ (only needed for the ./easypay.sh path)
docker compose up -d --build --remove-orphans
docker compose ps -a                                  # all services should be (healthy)
docker compose up -d --build easypay-service          # rebuild+restart one service (the usual workshop loop)
docker compose logs -f easypay-service
docker compose --profile=profiling up -d              # adds Pyroscope (compose.profiling.yml)
```

**Concurrent-build failures.** All seven service Dockerfiles share one *unnamed* BuildKit cache mount, `RUN --mount=type=cache,target=/root/.gradle`, and `--build` builds them in parallel, so they contend for it. Two distinct outcomes:

- **Gradle file-lock timeout** — transient. `./scripts/build-services.sh` (serial; `.ps1` on Windows) then `docker compose up -d --build` clears it.
- **Corrupted cache** — persistent, and the serial script does *not* fix it, because the damage is stored in the cache mount and re-read on every retry:

  ```
  > Could not read workspace metadata from /root/.gradle/caches/8.7/kotlin-dsl/scripts/<hash>/metadata.bin
  ```

  Purge just that entry rather than `docker builder prune` (which discards cache mounts for every project on the machine). The mount declares no `id=`, so its id defaults to the target path — a throwaway build claiming the same target reaches the same cache:

  ```dockerfile
  FROM eclipse-temurin:21-jdk-alpine
  RUN --mount=type=cache,target=/root/.gradle \
      rm -rf /root/.gradle/caches/8.7/kotlin-dsl /root/.gradle/caches/8.7/scripts /root/.gradle/caches/8.7/transforms
  ```

  `docker build --no-cache -f fixcache.Dockerfile .`, then rebuild the failed service. Downloaded dependencies under `caches/modules-2` survive, so the rebuild is quick.

Diagnose either one with `docker compose build --progress=plain <service>` redirected to a file, then grep `What went wrong`. Piping to `tail -30` truncates the BuildKit epilogue and hides the Gradle error entirely.

`compose.yml` includes `compose.infrastructure.yml` (backends + databases + Kafka), `compose.services.yml` (all microservices except easypay), `compose.profiling.yml`. **`easypay-service` is defined in `compose.yml` itself**, on purpose — it is the service attendees edit.

### Exercise the application

```bash
http POST :8080/api/easypay/payments posId=POS-01 cardNumber=5555567898780008 expiryDate=789456123 amount:=40000
k6 run -u 5 -d 2m k6/02-payment-smartbank.js   # calls easypay + smartbank
k6 run -u 1 -d 5m k6/01-payment-only.js        # payments only
```

`amount` above 10000 (`payment.author.threshold`) triggers the bank authorization call to smartbank-gateway — necessary to produce multi-service traces.

### Run a service on the host instead of in Docker

```bash
bash scripts/download-grafana-agent.sh   # instrumentation/grafana-opentelemetry-java.jar
./easypay.sh      # easypay on :8081, agent-instrumented, OTLP -> localhost:4317
./smartbank.sh
```

### Docs

```bash
git submodule update --init --recursive          # docs/themes/hugo-theme-relearn
hugo server -s docs                              # Hugo site (the /devoxxpl/ variant)
claat export -f html -o public docs/workshop.md  # Google CLAAT codelab (site root)
```

### On Windows

The workshop's own scripts are bash; PowerShell ports live beside them and are the ones to use on Windows.

```powershell
.\gradlew.bat build --parallel -x test
.\gradlew.bat :easypay-service:test --tests "com.worldline.easypay.easypayservice.EasypayServiceApplicationTests"

.\scripts\download-agent.ps1            # OTel Java agent          -> instrumentation\
.\scripts\download-grafana-agent.ps1    # Grafana OTel distro      -> instrumentation\
.\scripts\download-pyroscope-agent.ps1  # pyroscope + otel bridge  -> instrumentation\
.\scripts\build-services.ps1            # serial image build fallback

.\easypay.ps1                           # host run, :8081, agent-instrumented
.\smartbank.ps1

. .\scripts\payment-helpers.ps1         # dot-source: Send-Payment / Send-PaymentBurst
```

`scripts/payment-helpers.ps1` is the Windows stand-in for the guide's `http POST …` calls —
`Send-Payment [-PosId] [-CardNumber] [-ExpiryDate] [-Amount]` against `:8080/api/easypay/payments`,
and `Send-PaymentBurst -Count N` when k6 is not installed. It must be **dot-sourced** (`. .\…`);
running it as `.\scripts\payment-helpers.ps1` defines the functions in a child scope that is thrown
away, which is the cause of the recurring `Send-Payment: The term … is not recognized`. It has no
`.sh` twin: on Linux/macOS the workshop uses httpie directly.

`docker compose …` commands are identical on Windows.

**Line endings are load-bearing.** `gradlew` and every `*.sh` here execute *inside Linux containers* — the service Dockerfiles `RUN ./gradlew`, and the grafana/pyroscope images `COPY` + exec their `entrypoint.sh`. A Windows checkout with `core.autocrlf=true` gives them CRLF, the shebang becomes `#!/bin/sh\r`, and all seven Java service builds die with a misleading error:

```
#103 [api-gateway build 8/9] RUN --mount=type=cache,target=/root/.gradle ./gradlew :api-gateway:clean :api-gateway:build -x test
#103 1.252 /bin/sh: ./gradlew: not found
#103 ERROR: process "/bin/sh -c ./gradlew ..." did not complete successfully: exit code: 127
```

The file is present; the *interpreter* `/usr/bin/env sh\r` is not. `.gitattributes` in this repo pins `* text=auto eol=lf` (with `*.bat`/`*.cmd` kept CRLF) to prevent it. Diagnose with `git ls-files --eol gradlew` — `w/crlf` is the broken state, `w/lf` is correct. Note upstream has no `.gitattributes`, so a fresh clone on Windows reproduces this.

Notes on the bash/PowerShell split:

- The `download-*.sh` scripts do run under Git Bash unchanged (`curl`, `mkdir -p`, `dirname` all resolve). **`easypay.sh` / `smartbank.sh` do not** — they build paths with `$(pwd)`, which Git Bash renders as `/d/Projects/…`, and Windows `java` cannot resolve that for `-javaagent:` or `-jar`. That is why the `.ps1` runners exist; they resolve the repo root from `$PSScriptRoot` instead and fail with an explicit message when the agent jar or service jar is missing.
- `scripts/download-compose.sh` has no PowerShell port on purpose: it fetches a `linux-x86_64` Compose plugin binary. Docker Desktop already ships Compose v2.
- Keep the `.ps1` version constants in sync with their `.sh` twins when bumping agent versions (OTel agent `v2.11.0`, Grafana distro `v2.4.0-beta.1`, Pyroscope `v0.17.0` + otel-profiling-java `0.11.0`). Note these differ from the agent version baked into the service images (`OTEL_AGENT_VERSION v2.14.0` in each Dockerfile) — the host-run path and the container path are versioned separately.
- Execution policy: `LocalMachine` is `RemoteSigned`, so locally-authored scripts run unsigned. If the repo arrived as a downloaded zip, files carry a zone marker and need `Unblock-File .\*.ps1`.
- **k6 and httpie are not installed on this machine.** k6 must be installed natively rather than run in a container: `k6/*.js` hardcode `http://localhost:8080`, which a container would not reach. For one-off payments without httpie:

```powershell
Invoke-RestMethod -Method Post -Uri http://localhost:8080/api/easypay/payments `
  -ContentType application/json `
  -Body '{"posId":"POS-01","cardNumber":"5555567898780008","expiryDate":"789456123","amount":40000}'
```

## Endpoints / ports

| Port | Service |
|---|---|
| 8080 | api-gateway (only public entry point for the app) |
| 8761 | discovery-server (Eureka dashboard) |
| 8888 | config-server (management on 8890) |
| 3000 | Grafana (anonymous admin auth) |
| 3100 / 9090 / 3200 / 4040 | Loki / Prometheus / Tempo / Pyroscope |
| 4317 / 4318 | OpenTelemetry Collector, OTLP gRPC / HTTP |
| 5432 / 5433 / 5434 / 5435 | Postgres for easypay / smartbank / fraudetect / merchantbo |
| 19092 | Kafka (host listener; `kafka:9092` inside the network) |

Application containers are not port-mapped individually; reach them through the gateway.

## Architecture

**Request path.** `api-gateway` (Spring Cloud Gateway) routes `/api/easypay/**` → easypay-service, `/api/smartbank/**` → smartbank-gateway, `/api/fraudetect/**` → fraudetect-service, stripping two prefix segments. Note the easypay route targets `http://easypay-service:8080` **directly** rather than `lb://`, so restarting easypay does not require the gateway to refresh its Eureka cache — that is what makes the fast rebuild loop work.

**Payment flow.** `PaymentResource` → `PaymentService.accept()` → `PosValidator` (DB lookup) → `CardValidator` (Luhn / card type / blacklist) → above the threshold, `BankAuthorService` (OpenFeign + Resilience4j `@Retry` with an `acceptByDelegation` fallback) calls smartbank-gateway → persist → `PaymentTracker` publishes a `PaymentProcessedEvent` over Spring Cloud Stream to Kafka `payment-topic`, consumed by fraudetect-service and merchant-backoffice.

**easypay-service package layout** follows boundary/control/entity per aggregate (`payment`, `cardref`, `posref`): `boundary` = REST resources + DTOs, `control` = business logic, `entity` = JPA entities + repositories.

**Configuration is centralized in config-server.** Each service does `spring.config.import=optional:configserver:${CONFIG_SERVER_URL:http://localhost:8888}`. config-server serves files from its own classpath: `config-server/src/main/resources/config-server/{application,<service-name>}.yml` (`spring.cloud.config.server.native.searchLocations=classpath:/config-server`). So shared settings — actuator exposure, Micrometer histogram/percentile config, log file location, the `correlation` logging-pattern profile — live in `config-server/.../config-server/application.yml`, and **changing them requires rebuilding config-server**, not the consuming service. Per-service `src/main/resources/application.{yml,properties}` holds only bootstrap-level config (app name, config import, datasource, Kafka bindings).

Spring profiles in play: `docker` (in-network hostnames), `native` (config-server file backend), `json-logging`, `correlation`. Profiles are set per service via `SPRING_PROFILES_ACTIVE` in the compose files.

**Telemetry pipeline.** Services run with `-javaagent:/opentelemetry-javaagent.jar` (agent baked into each image by its Dockerfile via `ADD` from GitHub releases) and `OTEL_EXPORTER_OTLP_ENDPOINT=http://opentelemetry-collector:4317`. The collector (`docker/otelcol/otelcol.yaml`) fans out: logs → Loki `/otlp`, metrics → Prometheus `/api/v1/otlp`, traces → Tempo gRPC. Prometheus runs with `--web.enable-otlp-receiver` and `--enable-feature=exemplar-storage` (exemplars are a workshop chapter). Grafana **datasources are provisioned inline in the `grafana` entrypoint heredoc in `compose.infrastructure.yml`**, not under `docker/grafana/` — dashboards are the ones in `docker/grafana/dashboards/`.

Backend images are custom-tagged `<image>:observability-workshop`, built from `docker/<component>/Dockerfile` with a pinned `VERSION` build arg — bump versions there, not in the compose service definitions.

Service images are multi-stage and run the **exploded** jar (`java -cp app:app/lib/* com.worldline.easypay.<X>Application`), which is why entrypoints in compose are spelled out rather than `java -jar`. `docker/alloy/config.alloy` is unused legacy; nothing references it.

## Workshop invariants — do not "fix" these

- **easypay-service is intentionally un-instrumented.** Its `compose.yml` entrypoint has no `-javaagent` and no `OTEL_*` environment variables, while every service in `compose.services.yml` has both. Attendees add them chapter by chapter (agent → MDC/log attributes → `otel.metric.export.interval` → Pyroscope agent). Do not add instrumentation to easypay unless explicitly asked.
- **`POS-02` has `active = NULL`** in `easypay-service/src/main/resources/db/postgresql/data.sql`. `PosValidator.isActive()` unboxes `posList.get(0).active`, so any payment on POS-02 throws NPE. This is the "technical issue" chapter, and `k6/01-payment-only.js` deliberately mixes POS-01 and POS-02.
- **Commented-out `LOG.*` statements** (e.g. throughout `PaymentResource.java`) are exercise answers waiting to be uncommented.
- **smartbank-gateway** carries Hazelcast caching and `-Xmx2g` specifically to demonstrate a GC/OOM + cache-metrics incident under `k6/02-payment-smartbank.js`.
- `payment.author.threshold` (10000) and `payment.max.amount.fallback` (20000) tune which scenarios fire; several chapters depend on their current values.

## Documentation is maintained in two parallel forms

`.github/workflows/deploy-pages.yml` builds both and publishes them together (deploy step gated on `main`; `hugo-noprod.yml` / `claat-noprod.yml` validate branches and PRs):

- `docs/workshop.md` — single-file Google CLAAT codelab, served at the site root.
- `docs/content/**` — Hugo + hugo-theme-relearn site (a git submodule), served under `/devoxxpl/`, split per chapter.

A change to workshop instructions normally has to be applied in **both**. Chapter ordering in the Hugo site comes from the `weight` in each page's TOML front matter — currently `workshop-overview` 1, `prerequisites` 2, `logs` 3, `metrics` 4, `traces` 5, `correlation` 6, `profiling` 7.

## Environments

`.devcontainer/devcontainer.json` (Codespaces/devcontainer) provisions Java 21 + Docker-in-Docker + k6 and runs the whole setup in `postCreateCommand`. `.codesandbox/tasks.json` covers CodeSandbox. `ovhcoderlab/Dockerfile` is a fourth environment — an Ubuntu 24.04 image with JDK 21, Docker CE, k6, httpie for the OVH CodeLab hosting. Grafana and Pyroscope honor `VSCODE_PROXY_URI` so their root URLs work behind a cloud-IDE port proxy — keep that indirection if editing their entrypoints.

## Files that are not attendee-facing

- `agenda.md`, `scenario.md` — the authors' own planning/demo-flow notes (partly French), not published anywhere. Not a source of truth for behavior; don't sync them with `docs/`.
- `WINDOWS-GUIDE.md` — long-form Windows setup writeup, local to this checkout and untracked upstream. Overlaps [On Windows](#on-windows); update both together when the Windows story changes.
- `logs/` — runtime log output directory (services write there via the config-server `logging.file` setting), not source.
