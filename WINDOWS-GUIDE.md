# Observability Workshop — Windows Guide

Run the workshop on Windows with PowerShell 7+. Every command below is copy-paste ready from the repo
root.

| Icon | Meaning |
|---|---|
| 🛠️ | Run this |
| 📝 | Edit a file |
| 👀 | Look at the result |
| ✅ | Verify |
| ⚠️ | Windows-specific trap |

---

## Read first — load the `Send-Payment` helper

Almost every step of this guide sends a payment with `Send-Payment`. It is **not** a cmdlet and not on
your `PATH`: it is a PowerShell function living in [`scripts\payment-helpers.ps1`](scripts/payment-helpers.ps1),
and it exists only in sessions where you have loaded that file. Close the window, or open a second
one, and it is gone.

```
Send-Payment: The term 'Send-Payment' is not recognized as a name of a cmdlet, function, script
file, or executable program.
```

That error always means the same thing — new window, helper not loaded. Fix, once per window:

```powershell
. .\scripts\payment-helpers.ps1
```

⚠️ The leading `.` followed by a space is **not** decoration. `. .\script.ps1` is dot-sourcing: it
runs the file in the *current* session, so its functions stay. `.\script.ps1` runs it in a child scope
that is discarded immediately — no error, no functions, and `Send-Payment` is still unrecognized.

Load it in every future window instead:

```powershell
Add-Content $PROFILE ". `"$PWD\scripts\payment-helpers.ps1`""
```

Then reopen the terminal. Check with `Get-Command Send-Payment` — it prints a `Function`, or throws
the error above.

### What the helper gives you

`Send-Payment` defaults to POS-01, a valid MasterCard number, and `-Amount 25000` — above
`payment.author.threshold` (10000), so the call reaches smartbank-gateway and produces a
multi-service trace. Override any parameter:

```powershell
Send-Payment                                            # ACCEPTED
Send-Payment -Amount 51000                              # AUTHORIZATION_DENIED
Send-Payment -CardNumber 5555567898780007 -Amount 25000 # INVALID_CARD_NUMBER
Send-Payment -PosId POS-02 -Amount 25000                # HTTP 500 (the "technical issue" chapter)
```

`Send-PaymentBurst` fires many in a row and discards the responses — the traffic generator for the
chapters where k6 is optional:

```powershell
Send-PaymentBurst -Count 50 -Amount 40000
```

Nothing answers until the stack is up ([Chapter 1](#chapter-1--start-the-infrastructure)); before
that you get a connection error, not a payment response.

See [Sending payments](#sending-payments) for the design notes and a `curl.exe` equivalent.

---

## Status of this checkout

The exercises are edits *you* make to the application, so a working copy drifts from upstream as you
progress. Applied here so far:

| Step | Change | File |
|---|---|---|
| 2.2 | `LOG.*` statements uncommented | `easypay-service/.../payment/boundary/PaymentResource.java` |
| 2.3 | `isActive()` wrapped in `try/catch (NullPointerException)` + `LOG.warn` | `easypay-service/.../payment/control/PosValidator.java` |
| 2.4 | `MDC.put`/`MDC.clear()` active, `logging.pattern.level: "%5p [%mdc]"` | same `PaymentResource.java`, `easypay-service/src/main/resources/application.yaml` |
| 2.6 | `-javaagent`, both `logback-appender` properties, three `OTEL_*` env vars | `compose.yml` |
| 2.8 | `redaction/card-numbers` processor on the `logs` pipeline | `docker/otelcol/otelcol.yaml` |
| 3.1 | `-Dotel.metric.export.interval=5000` | `compose.yml` |
| 3.5 | `io.opentelemetry:opentelemetry-api`; two `LongHistogram` + one `LongCounter` | `easypay-service/build.gradle.kts`, `easypay-service/.../payment/control/PaymentService.java` |
| 4.2 | `tail_sampling/actuator` processor on the `traces` pipeline | `docker/otelcol/otelcol.yaml` |
| 4.3 | `opentelemetry-instrumentation-annotations` dependency (docs wrongly say it is pre-added); `@WithSpan` + `@SpanAttribute` on `process`/`store` | `easypay-service/build.gradle.kts`, `easypay-service/.../payment/control/PaymentService.java` |
| 6.2 | 11 `PYROSCOPE_*`/`OTEL_PYROSCOPE_*`/`OTEL_JAVAAGENT_EXTENSIONS` env vars, `-javaagent:/pyroscope.jar` | `compose.yml` |

**Not applied: 2.5** (masking the card number in the application's own logs). Since 2.8 redacts at the
collector, Grafana already shows `****`; the full PAN is still visible in
`docker compose logs easypay-service`.

`git diff` is the source of truth if this table falls behind.

---

## Table of contents

1. [Read first — load the `Send-Payment` helper](#read-first--load-the-send-payment-helper)
2. [Status of this checkout](#status-of-this-checkout)
3. [Quick reference — every command, in order](#quick-reference--every-command-in-order)
4. [Chapter 0 — Setup (read this first)](#chapter-0--setup-read-this-first)
5. [Chapter 1 — Start the infrastructure](#chapter-1--start-the-infrastructure)
6. [Chapter 2 — Logs](#chapter-2--logs)
7. [Chapter 3 — Metrics](#chapter-3--metrics)
8. [Chapter 4 — Traces](#chapter-4--traces)
9. [Chapter 5 — Correlation](#chapter-5--correlation)
10. [Chapter 6 — Profiling (bonus)](#chapter-6--profiling-bonus)
11. [Appendix — Troubleshooting](#appendix--troubleshooting)

---

## Quick reference — every command, in order

`📝` marks a file edit with no command — follow the linked section for the code. `🖥️` marks Grafana
UI work. Everything else is copy-paste.

### Setup (once)

```powershell
git ls-files --eol gradlew          # must print "w/lf". "w/crlf" -> see Chapter 0
java -version                       # 21+
docker compose version              # v2+
winget install k6 --source winget   # or: choco install k6
k6 version
'VSCODE_PROXY_URI=' | Set-Content .env   # silences the compose warning
```

Then load the [`Send-Payment` helper](#read-first--load-the-send-payment-helper) —
`. .\scripts\payment-helpers.ps1`. Nearly every step needs it, and it is gone in the next window.

### Chapter 1 — start the stack

```powershell
.\scripts\download-agent.ps1
.\gradlew.bat build --parallel -x test
docker compose up -d --build --remove-orphans     # first run: 10-20 min
docker compose ps -a                              # all app services "(healthy)"
Send-Payment -Amount 25000                        # expect responseCode ACCEPTED
```

Then confirm five instances at <http://localhost:8761>.

⚠️ If the build fails, read [the build failures section](#build-fails-during-docker-compose-up---build)
before retrying — one of the two failure modes never clears on its own.

### Chapter 2 — logs

```powershell
docker compose logs -f easypay-service
Send-Payment -Amount 51000                              # AUTHORIZATION_DENIED
Send-Payment -CardNumber 5555567898780007 -Amount 25000 # INVALID_CARD_NUMBER
```

📝 [2.2](#22-add-contextual-logs) uncomment the `LOG.…` lines in `PaymentResource.java`.

```powershell
Send-Payment -PosId POS-02 -Amount 25000    # HTTP 500, bare NullPointerException
```

📝 [2.3](#23-the-technical-issue) wrap `PosValidator.isActive()` in try/catch + `LOG.warn`.

```powershell
docker compose up -d --build easypay-service   # THE loop, ~30-60s, repeated all workshop long
Send-Payment -PosId POS-02 -Amount 25000       # POS ID now named in the log
k6 run -u 5 -d 5s k6/01-payment-only.js        # interleaved logs -> motivates MDC
```

📝 [2.4](#24-mapped-diagnostic-context-mdc) `MDC.put`/`MDC.clear()` in `processPayment()` +
`logging.pattern.level` in `application.yaml`.

```powershell
docker compose up -d --build easypay-service
k6 run -u 5 -d 5s k6/01-payment-only.js
```

📝 [2.6](#26-attach-the-opentelemetry-java-agent) add `-javaagent:/opentelemetry-javaagent.jar`, the
two `logback-appender` properties, and the three `OTEL_*` env vars to `easypay-service` in
`compose.yml`.

```powershell
docker compose up -d easypay-service
docker compose logs easypay-service | Select-String "otel.javaagent"   # proves the agent attached
Send-Payment -Amount 40000
```

🖥️ [2.7](#27-explore-logs-in-grafana) Grafana <http://localhost:3000> → Explore → Loki.

📝 [2.8](#28-pii-obfuscation) add `redaction/card-numbers` to `docker/otelcol/otelcol.yaml`.

```powershell
docker compose up -d --build opentelemetry-collector
Send-Payment -Amount 40000                     # card numbers now ****
```

### Chapter 3 — metrics

📝 [3.1](#31-speed-up-the-export-interval) add `-Dotel.metric.export.interval=5000` to the entrypoint.

```powershell
docker compose up -d --build easypay-service
k6 run -u 5 -d 2m k6/02-payment-smartbank.js   # the OOM incident; needs k6
docker compose restart smartbank-gateway       # recover
```

🖥️ [3.2](#32-explore-metrics)–[3.4](#34-incident-needs-k6) Prometheus in Explore; import dashboards
`17582` and `19732`.

📝 [3.5](#35-business-metrics) add `io.opentelemetry:opentelemetry-api` to
`easypay-service/build.gradle.kts`, then the two `LongHistogram`s + `LongCounter` in `PaymentService`.

```powershell
docker compose up -d --build easypay-service
docker compose logs -f easypay-service          # wait for "Started EasypayServiceApplication"
k6 run -u 1 -d 1m k6/01-payment-only.js
# no k6:
Send-PaymentBurst -Count 50 -Amount 40000
Get-Content docker\grafana\dashboards\easypay-monitoring.json -Raw | Set-Clipboard  # then Import
k6 run -u 2 -d 2m k6/01-payment-only.js         # watch the dashboard live
```

### Chapter 4 — traces

```powershell
k6 run -u 1 -d 5m k6/01-payment-only.js    # Tempo needs 1-2 min before traces show
```

🖥️ [4.1](#41-explore-traces) Explore → Tempo; enable **node graph** on the datasource.

📝 [4.2](#42-sampling) add `tail_sampling/actuator` to `docker/otelcol/otelcol.yaml`.

```powershell
docker compose up -d --build opentelemetry-collector
```

📝 [4.3](#43-custom-spans) annotate `process`/`store` with `@WithSpan` + `@SpanAttribute`.

```powershell
docker compose up -d --build easypay-service
Send-Payment -Amount 40000
```

### Chapter 5 — correlation

All Grafana datasource configuration, no file edits and almost no commands:

- [5.1](#51-logs--traces) Loki → derived field `TraceID` → Tempo.
- [5.2](#52-metrics--traces-exemplars) Prometheus → Exemplars → internal link to Tempo.
- [5.3](#53-traces--logs) Tempo → Trace to logs → Loki.
- [5.4](#54-traces--metrics) Tempo → Trace to metrics → Prometheus, plus the two queries.

```powershell
k6 run -u 1 -d 2m k6/01-payment-only.js    # traffic for 5.2
Send-Payment -Amount 40000                 # a trace to click through in 5.3 / 5.4
```

### Chapter 6 — profiling (bonus)

```powershell
docker compose --profile=profiling up -d   # Pyroscope on :4040
```

📝 [6.2](#62-instrument-easypay-for-profiling) add the `PYROSCOPE_*` / `OTEL_PYROSCOPE_*` env vars and
`-javaagent:/pyroscope.jar` to `easypay-service` in `compose.yml`.

```powershell
docker compose up -d easypay-service
docker compose logs -f easypay-service      # expect Pyroscope lines at startup
k6 run -u 1 -d 5m k6/02-payment-smartbank.js
```

🖥️ [6.3](#63-pyroscope-in-grafana) Explore → Pyroscope. [6.4](#64-traces--profiles) Tempo → Trace to
profiles → Pyroscope.

### When something breaks

```powershell
docker compose ps                                       # who is unhealthy
docker compose logs --tail=50 easypay-service
docker compose logs --tail=50 opentelemetry-collector   # no data in Grafana
docker compose config                                   # validate compose.yml after editing
docker compose down -v --remove-orphans                 # nuke, incl. DB volumes
```

Full symptom list in the [Appendix](#appendix--troubleshooting).

---

## Chapter 0 — Setup (read this first)

### ⚠️ The one trap that will break your build: line endings

This is the single most important section of this guide.

`gradlew` and every `*.sh` file in this repo execute **inside Linux containers** — the service
Dockerfiles run `./gradlew`, and the Grafana/Pyroscope images `COPY` and exec their `entrypoint.sh`.

If Git checks those files out with Windows CRLF line endings, the shebang line becomes `#!/bin/sh\r`.
Linux then looks for an interpreter literally named `sh\r`, does not find it, and reports:

```
#103 [api-gateway build 8/9] RUN --mount=type=cache,target=/root/.gradle ./gradlew :api-gateway:clean :api-gateway:build -x test
#103 1.252 /bin/sh: ./gradlew: not found
#103 ERROR: process "/bin/sh -c ./gradlew ..." did not complete successfully: exit code: 127
```

The error says *"not found"* about a file that is plainly there. The file exists; the **interpreter**
does not. All seven Java services fail this way at once.

🛠️ Diagnose:

```powershell
git ls-files --eol gradlew
```

- `i/lf    w/lf` → correct, move on.
- `i/lf    w/crlf` → broken, fix it below.

🛠️ Fix:

```powershell
# 1. .gitattributes must pin LF:  * text=auto eol=lf   +   *.bat/*.cmd text eol=crlf

# 2. Rewrite the affected files in place
$targets = @(git ls-files "*.sh") + @('gradlew')
foreach ($f in $targets) {
    $bytes = [System.IO.File]::ReadAllBytes($f)
    if ($bytes -notcontains 13) { continue }
    $text = [System.IO.File]::ReadAllText($f) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText((Resolve-Path $f).Path, $text, (New-Object System.Text.UTF8Encoding($false)))
    "converted to LF: $f"
}

# 3. Confirm nothing but line endings changed
git update-index --refresh | Out-Null
git diff --stat   # should be empty
```

⚠️ Files affected beyond `gradlew`: `docker/grafana/entrypoint.sh` and `docker/pyroscope/entrypoint.sh`.
Those two fail at **container runtime**, not build time — so if you only fix `gradlew`, the build
succeeds and Grafana silently refuses to start later.

The underlying cause is `core.autocrlf=true` (check with `git config --get core.autocrlf`) with no
`.gitattributes` to override it. Keep the `.gitattributes` and you never see this again.

### Required tools

🛠️ Verify each one:

```powershell
java -version           # need 21+
docker version          # daemon must be running
docker compose version  # v2+
git --version
$PSVersionTable.PSVersion  # PowerShell 7+ recommended
```

⚠️ **Do not install Gradle.** Use the wrapper — on Windows that is `.\gradlew.bat`, not `./gradlew`.

### Windows script equivalents

Use these instead of the `.sh` versions. They resolve paths from `$PSScriptRoot`, so they work from
any working directory.

```powershell
.\scripts\download-agent.ps1            # OTel Java agent          -> instrumentation\
.\scripts\download-grafana-agent.ps1    # Grafana OTel distro      -> instrumentation\
.\scripts\download-pyroscope-agent.ps1  # pyroscope + otel bridge  -> instrumentation\
.\scripts\build-services.ps1            # serial image build fallback
.\easypay.ps1                           # run easypay on the host, :8081
.\smartbank.ps1                         # run smartbank on the host
```

`docker compose …`, `k6 run …` and `.\gradlew.bat …` need no translation beyond the `.bat`.

⚠️ `easypay.sh` and `smartbank.sh` **cannot** be used from Git Bash on Windows: they build
`-javaagent:$(pwd)/...`, and Git Bash renders `$(pwd)` as `/d/Projects/...`, which the Windows JVM
cannot resolve. Use the `.ps1` versions. The `download-*.sh` scripts do work under Git Bash.

⚠️ `scripts/download-compose.sh` has no Windows equivalent — it fetches a `linux-x86_64` Compose
binary. Docker Desktop already bundles Compose v2.

### Sending payments

The helper lives in [`scripts\payment-helpers.ps1`](scripts/payment-helpers.ps1); loading it is
covered at the top of this guide:
[Read first — load the `Send-Payment` helper](#read-first--load-the-send-payment-helper). Two things
about how it is written:

The `catch` block matters: `Invoke-RestMethod` throws on non-2xx, and without it you lose the
response body you are supposed to read.

`amount` must be a JSON **number**; `ConvertTo-Json` gets that right because the parameter is typed
`[int]`.

If you prefer raw curl, `curl.exe` ships with Windows 10/11:

```powershell
curl.exe -i -X POST http://localhost:8080/api/easypay/payments `
  -H "Content-Type: application/json" `
  -d '{"posId":"POS-01","cardNumber":"5555567898780008","expiryDate":"789456123","amount":25000}'
```

⚠️ Write `curl.exe`, not `curl`. In PowerShell 5.1 `curl` is an alias for `Invoke-WebRequest`, which
takes completely different arguments. (PowerShell 7 drops the alias, but being explicit is portable.)

### ⚠️ Installing k6

Several chapters need [k6](https://k6.io/) for load generation. Install it **natively on Windows** —
do not run it in a container, because `k6/*.js` hardcode `http://localhost:8080`, which a container
cannot reach.

```powershell
winget install k6 --source winget
# or
choco install k6
k6 version
```

If either command fails, check the current package name at
<https://grafana.com/docs/k6/latest/set-up/install-k6/>; an MSI is available there too.

Chapters needing k6 are marked. You can complete Logs, Traces and Correlation without it by sending
single payments — you just get less traffic to look at. The **Metrics → Incident** chapter genuinely
needs k6 to trigger the OOM.

### ⚠️ Silencing the compose warning

Every compose command prints this twice:

```
level=warning msg="The \"VSCODE_PROXY_URI\" variable is not set. Defaulting to a blank string."
```

Harmless — the variable only matters in cloud IDEs. To silence it, create a `.env` file next to
`compose.yml`:

```dotenv
VSCODE_PROXY_URI=
```

### ⚠️ Editing files

Any editor is fine, but if your editor writes CRLF, do not let it touch `gradlew` or `*.sh`. The
`.gitattributes` protects Git; it does not stop an editor from rewriting a file on disk. Editing
`compose.yml`, `*.java`, `*.yaml` and `*.kts` with CRLF is harmless — those parsers do not care.

---

## Chapter 1 — Start the infrastructure

The stack is:

- one PostgreSQL instance per microservice,
- one Kafka broker,
- a Eureka service-discovery server and a Spring Cloud config server,
- the microservices: `api-gateway`, `easypay-service`, `merchant-backoffice`, `fraudetect-service`,
  `smartbank-gateway`,
- the observability backends: OpenTelemetry Collector, Loki, Prometheus, Tempo, Grafana.

🛠️ Download the OpenTelemetry Java agent:

```powershell
.\scripts\download-agent.ps1
```

This feeds the *host-run* path (`.\easypay.ps1`) only; the container images download their own agent
at build time. Harmless to run, and later chapters assume you did.

🛠️ Build and start everything:

```powershell
.\gradlew.bat build --parallel -x test
docker compose up -d --build --remove-orphans
```

⚠️ First run downloads a lot (base images, agents, all Gradle dependencies × 7 services). Expect
10–20 minutes. Later runs are cached and take seconds.

⚠️ Concurrent builds can fail on the shared Gradle cache. If the build errors out, go to
[build failures](#build-fails-during-docker-compose-up---build) — retrying blindly wastes 15 minutes
on one of the two failure modes.

✅ Check every service is healthy:

```powershell
docker compose ps -a
```

A compact view:

```powershell
docker compose ps --format "table {{.Service}}`t{{.Status}}"
```

Every application service should read `Up ... (healthy)`.

✅ Open the Eureka dashboard at <http://localhost:8761> and confirm five registered instances:

- `API-GATEWAY`
- `EASYPAY-SERVICE`
- `FRAUDETECT-SERVICE`
- `MERCHANT-BACKOFFICE`
- `SMARTBANK-GATEWAY`

⚠️ Wait for all five before continuing. Registration lags container startup by up to a minute.

From PowerShell instead of the browser:

```powershell
$r = Invoke-RestMethod -Uri 'http://localhost:8761/eureka/apps' -Headers @{Accept='application/json'}
$r.applications.application | ForEach-Object { "$($_.name) : $($_.instance.status)" }
```

✅ Send your first payment:

```powershell
Send-Payment -Amount 25000
```

Expected:

```
amount        : 25000
authorId      : 5d364f1a-569c-4c1d-9735-619947ccbea6
authorized    : True
bankCalled    : True
cardNumber    : 5555567898780008
cardType      : MASTERCARD
paymentId     : 3cd8df14-8c39-460b-a429-dc113d003aed
posId         : POS-01
processingMode: STANDARD
responseCode  : ACCEPTED
responseTime  : 414
```

Amounts above `10000` (`payment.author.threshold`) make easypay call `smartbank-gateway`. That is
what produces multi-service traces later, so prefer amounts above the threshold. `smartbank-gateway`
authorizes up to `40000` and denies above it.

### Ports

| Port | Service |
|---|---|
| 8080 | api-gateway — the only public entry point |
| 8761 | Eureka dashboard |
| 8888 | config-server |
| 3000 | Grafana (anonymous admin, no login) |
| 3100 | Loki |
| 9090 | Prometheus |
| 3200 | Tempo |
| 4040 | Pyroscope (profiling chapter only) |
| 4317 / 4318 | OpenTelemetry Collector, OTLP gRPC / HTTP |
| 5432–5435 | Postgres: easypay / smartbank / fraudetect / merchantbo |
| 19092 | Kafka (host listener) |

---

## Chapter 2 — Logs

### 2.1 Some functional issues

🛠️ Watch the easypay logs:

```powershell
docker compose logs -f easypay-service
```

A customer reports: *"When I reach your API, I usually get either an `AMOUNT_EXCEEDED` or an
`INVALID_CARD_NUMBER` error."*

🛠️ Reproduce `AUTHORIZATION_DENIED` — any amount above `40000` is refused by the bank:

```powershell
Send-Payment -Amount 51000
```

🛠️ Reproduce `INVALID_CARD_NUMBER` (note the trailing `7` — it fails the Luhn check):

```powershell
Send-Payment -CardNumber 5555567898780007 -Amount 25000
```

👀 Look in the console logs and try to pinpoint these two issues. You will find almost nothing
useful — that is the point of the exercise.

### 2.2 Add contextual logs

The workshop uses SLF4J. A logger is declared as:

```java
private static final Logger LOG = LoggerFactory.getLogger(PaymentResource.class);
```

Log levels, briefly: `TRACE` (fine-grained diagnostics), `DEBUG` (program state), `INFO` (normal
operation), `WARN` (potential problem worth investigating), `ERROR` (unexpected failure needing
attention).

📝 Edit `easypay-service/src/main/java/com/worldline/easypay/payment/boundary/PaymentResource.java`
and **uncomment every `// LOG.…` line**, including the logger declaration at the top of the class.
Leave the `MDC` lines commented — they come in section 2.4.

Those commented-out lines are exercise material, not dead code.

### 2.3 The technical issue

Another issue was reported for point of sale `POS-02`.

🛠️ Trigger it:

```powershell
Send-Payment -PosId POS-02 -Amount 25000
```

👀 You get an HTTP 500:

```
HTTP 500
{"error":"Internal Server Error","path":"/payments","status":500, ...}
```

👀 And in the logs, a bare stack trace with no business context:

```
java.lang.NullPointerException: Cannot invoke "java.lang.Boolean.booleanValue()" because "java.util.List.get(int).active" is null
        at com.worldline.easypay.payment.control.PosValidator.isActive(PosValidator.java:34)
        at com.worldline.easypay.payment.control.PaymentService.process(PaymentService.java:46)
        ...
```

📝 Add a *smart* log entry. In
`easypay-service/src/main/java/com/worldline/easypay/payment/control/PosValidator.java`, wrap
`isActive()` so the failure names the offending POS:

```java
public boolean isActive(String posId) {
    PosRef probe = new PosRef();
    probe.posId = posId;
    try {
        List<PosRef> posList = posRefRepository.findAll(Example.of(probe));

        if (posList.isEmpty()) {
            LOG.warn("checkPosStatus NOK, unknown posId {}", posId);
            return false;
        }

        boolean result = posList.get(0).active;

        if (!result) {
            LOG.warn("checkPosStatus NOK, inactive posId {}", posId);
        }
        return result;
    } catch (NullPointerException e) {
        LOG.warn("Invalid value for this POS: {}", posId);
        throw e;
    }
}
```

🛠️ Rebuild and redeploy just easypay — this is the loop you will repeat all workshop long:

```powershell
docker compose up -d --build easypay-service
```

⚠️ This takes ~30–60s on Windows. It is fast because `api-gateway` routes to
`http://easypay-service:8080` directly instead of through Eureka load balancing, so the gateway needs
no cache refresh.

🛠️ Re-run the failing request and check the logs again. The POS ID now appears, pointing at `POS-02`.

🛠️ *(needs k6)* Now make it realistic:

```powershell
k6 run -u 5 -d 5s k6/01-payment-only.js
```

👀 Check the logs again. They are interleaved across concurrent requests and it is now much harder to
tell which POS caused which error. This motivates MDC.

👀 Look at `easypay-service/src/main/resources/db/postgresql/data.sql` — `POS-02` has `NULL` in the
`active` column instead of a boolean.

**Leave the bug in place.** It is used again in the Traces chapter.

### 2.4 Mapped Diagnostic Context (MDC)

MDC is a map attached to the thread context. Put values in at the start of a request and every log
line from that request can print them.

📝 In `PaymentResource`, modify `processPayment()`:

```java
public ResponseEntity<PaymentResponse> processPayment(PaymentRequest paymentRequest) {
    // Add cardNumber to SLF4J MDC
    MDC.put("cardNumber", paymentRequest.cardNumber());
    // Add Point Of Sale identifier to SLF4J MDC
    MDC.put("pos", paymentRequest.posId());

    try { // wrap the original body of the method here
        //...
        return httpResponse;
    } catch (Exception e) {
        // Catch any exception so it is logged with the MDC values attached
        LOG.error(e.getMessage());
        throw e;
    } finally {
        MDC.clear(); // always clear, or you leak context between requests
    }
}
```

⚠️ Do not skip `MDC.clear()`. Thread pools reuse threads, so a stale MDC leaks one request's card
number into another request's logs.

📝 Print the values. In `easypay-service/src/main/resources/application.yaml`:

```yaml
logging:
  pattern:
    level: "%5p [%mdc]"
```

`%mdc` prints the whole map. For specific keys use `%X{key}`:

```yaml
logging:
  pattern:
    level: "%5p [%X{cardNumber} - %X{pos}]"
```

🛠️ Rebuild:

```powershell
docker compose up -d --build easypay-service
```

🛠️ *(needs k6)* Generate traffic and observe that every line now carries its card number and POS:

```powershell
k6 run -u 5 -d 5s k6/01-payment-only.js
```

### 2.5 Structured logging (optional)

📝 Optionally switch the console format in `application.yaml` to `ecs`, `gelf` or `logstash`:

```yaml
logging:
  structured:
    format:
      console: ecs
```

🛠️ Rebuild and look at the output:

```powershell
docker compose up -d --build easypay-service
docker compose logs -f easypay-service
```

👀 Logs are now JSON — harder for humans, ideal for log concentrators.

### 2.6 Attach the OpenTelemetry Java agent

`easypay-service` is the **only** service without instrumentation. Every other service already runs
with `-javaagent`. Adding it is your job, chapter by chapter.

The agent jar is already inside the image, placed there by
`easypay-service/src/main/docker/Dockerfile`:

```dockerfile
ENV OTEL_AGENT_VERSION "v2.14.0"
ENV OTEL_AGENT_URL "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar"

ADD --chown=$UID:$GID ${OTEL_AGENT_URL} /opentelemetry-javaagent.jar
```

📝 Edit `compose.yml` — attach the agent to `easypay-service`:

```yaml
services:
  easypay-service:
    # ...
    entrypoint:
      - java
      - -javaagent:/opentelemetry-javaagent.jar # < Add this line
      - -cp
      - app:app/lib/*
      - com.worldline.easypay.EasypayServiceApplication
```

📝 And point it at the collector, in the same service's `environment:` block:

```yaml
services:
  easypay-service:
    # ...
    environment:
      # ...
      OTEL_RESOURCE_ATTRIBUTES: "service.name=easypay-service,deployment.environment=dev,service.namespace=service,service.version=1.0.0,service.instance.id=easypay-service:8080"
      OTEL_EXPORTER_OTLP_PROTOCOL: grpc
      OTEL_EXPORTER_OTLP_ENDPOINT: http://opentelemetry-collector:4317
```

⚠️ `easypay-service` is defined in `compose.yml` itself, **not** in `compose.services.yml`. That is
deliberate — it is the file you edit. Everything else lives in `compose.services.yml` and
`compose.infrastructure.yml`.

📝 Enable MDC export (experimental, so it needs opting in). Add two system properties to the same
`entrypoint`:

```yaml
    entrypoint:
      - java
      - -javaagent:/opentelemetry-javaagent.jar
      - -Dotel.instrumentation.logback-appender.experimental-log-attributes=true       # < Add
      - -Dotel.instrumentation.logback-appender.experimental.capture-mdc-attributes=*  # < Add
      - -cp
      - app:app/lib/*
      - com.worldline.easypay.EasypayServiceApplication
```

🛠️ Redeploy:

```powershell
docker compose up -d easypay-service
```

✅ Confirm the agent attached:

```powershell
docker compose logs easypay-service | Select-String "otel.javaagent"
```

Expected:

```
easypay-service  | [otel.javaagent ...] [main] INFO io.opentelemetry.javaagent.tooling.VersionLogger - opentelemetry-javaagent - version: 2.14.0
```

⚠️ `Select-String` is the PowerShell equivalent of `grep`. Drop `-f` from `docker compose logs` when
filtering — `-f` never terminates.

The collector is already configured to receive logs and forward them to Loki — see
`docker/otelcol/otelcol.yaml`, pipeline `logs: otlp → batch → otlphttp/loki`.

### 2.7 Explore logs in Grafana

🛠️ Open <http://localhost:3000> (anonymous admin — no login).

- Open **Explore**,
- select the **Loki** datasource,
- in `Label filter`, pick `service_name` = `easypay-service`,
- click **Run query**, and unfold some log lines.

🛠️ Generate logs, whichever you prefer:

```powershell
Send-Payment -Amount 40000
# or
k6 run -u 1 -d 1m k6/01-payment-only.js
```

👀 Look at other services too (`api-gateway`). And notice something alarming: the card numbers are
in the logs. 😨

### 2.8 PII obfuscation

The collector's contrib distribution has a `redaction` processor.

📝 Edit `docker/otelcol/otelcol.yaml`:

```yaml
processors:
  batch:

  redaction/card-numbers:
    allow_all_keys: true
    blocked_values:
      - "4[0-9]{12}(?:[0-9]{3})?" ## VISA
      - "(5[1-5][0-9]{14}|2(22[1-9][0-9]{12}|2[3-9][0-9]{13}|[3-6][0-9]{14}|7[0-1][0-9]{13}|720[0-9]{12}))" ## MasterCard
      - "3(?:0[0-5]|[68][0-9])[0-9]{11}" ## Diners Club
      - "3[47][0-9]{13}" ## American Express
      - "65[4-9][0-9]{13}|64[4-9][0-9]{13}|6011[0-9]{12}|(622(?:12[6-9]|1[3-9][0-9]|[2-8][0-9][0-9]|9[01][0-9]|92[0-5])[0-9]{10})" ## Discover
      - "(?:2131|1800|35[0-9]{3})[0-9]{11}" ## JCB
      - "62[0-9]{14,17}" ## UnionPay
    summary: debug

service:
  pipelines:
    logs:
      receivers: [otlp]
      processors: [batch, redaction/card-numbers]  # < attach it here
      exporters: [otlphttp/loki]
```

🛠️ Restart the collector:

```powershell
docker compose up -d --build opentelemetry-collector
```

🛠️ Generate more logs, then ✅ confirm card numbers now show as `****`.

---

## Chapter 3 — Metrics

Goal: collect metrics and forward them to Prometheus, again through the collector.

### 3.1 Speed up the export interval

The agent already collects metrics, but ships them every 60s — too slow for a workshop.

📝 In `compose.yml`, add one more system property to the easypay `entrypoint`:

```yaml
    entrypoint:
      - java
      - -javaagent:/opentelemetry-javaagent.jar
      - -Dotel.instrumentation.logback-appender.experimental-log-attributes=true
      - -Dotel.instrumentation.logback-appender.experimental.capture-mdc-attributes=*
      - -Dotel.metric.export.interval=5000 # < Add this line
      - -cp
      - app:app/lib/*
      - com.worldline.easypay.EasypayServiceApplication
```

Any agent system property has an env-var twin: `otel.metric.export.interval` →
`OTEL_METRIC_EXPORT_INTERVAL`.

🛠️ Restart:

```powershell
docker compose up -d --build easypay-service
```

The collector already forwards metrics to Prometheus via
`otlphttp/prometheus: http://prometheus:9090/api/v1/otlp`. Prometheus runs with
`--web.enable-otlp-receiver`.

### 3.2 Explore metrics

🛠️ In Grafana → **Explore**, select the **Prometheus** datasource.

- Pick the metric `jvm_memory_used_bytes`, **Run query**.
- Add **Operations** → **Aggregations** → **Sum** for total memory across JVMs.
- Use **By label** → `service_name` to split per service.
- Use **Label filters** to narrow to `easypay-service`.

👀 The generated query is PromQL:
`sum by(service_name) (jvm_memory_used_bytes{service_name="easypay-service"})`.

### 3.3 Import dashboards

🛠️ Grafana → **Dashboards** → **New** → **Import**, paste an ID, **Load**, select the Prometheus
datasource:

- `17582` — JMX / JVM Micrometer overview
- `19732` — OpenTelemetry JDBC (Spring Boot / HikariCP)

👀 Explore the JMX dashboard; the `job` filter selects the service.

### 3.4 Incident! *(needs k6)*

🛠️ Generate load that also hammers smartbank:

```powershell
k6 run -u 5 -d 2m k6/02-payment-smartbank.js
```

👀 In the **JVM Micrometer** dashboard, watch `easypay-service` — especially garbage collection and
CPU. Then check the **OpenTelemetry JDBC** dashboard for the connection pool.

👀 Switch to **Explore** → **Loki** and query the errors:

- Label filter: `service_name` = `smartbank-gateway`
- Label filter expression: label `detected_level`, operator `=~`, value `warn|error`

You should find a `java.lang.OutOfMemoryError` — a saturated Java heap.

👀 Back in **JMX Overview**, select `smartbank-gateway`: used heap reaches the maximum allowed.

This is by design. `smartbank-gateway` runs with Hazelcast caching and a capped heap specifically to
blow up under this load profile.

🛠️ Recover:

```powershell
docker compose restart smartbank-gateway
```

### 3.5 Business metrics

Observability is not only incidents — define your own metrics. OpenTelemetry offers **Counters**
(monotonic), **Gauges** (current value) and **Histograms** (distributions, e.g. latency).

Goal: measure time spent in `process` and `store` of
`com.worldline.easypay.payment.control.PaymentService`, and count payment requests.

📝 **1. Add the dependency** to `easypay-service/build.gradle.kts`:

```kotlin
dependencies {
    // ...
    implementation("io.opentelemetry:opentelemetry-api")
}
```

📝 **2. Declare the histograms** in `PaymentService`:

```java
import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.metrics.LongHistogram;

@Service
public class PaymentService {
    // ...
    private LongHistogram processHistogram;
    private LongHistogram storeHistogram;

    public PaymentService(/* ... */) {
        // ...
        OpenTelemetry openTelemetry = GlobalOpenTelemetry.get();

        processHistogram = openTelemetry.getMeter(EasypayServiceApplication.class.getName())
                .histogramBuilder("easypay.payment.process")
                .setDescription("Payment processing time")
                .setUnit("ms")
                .ofLongs()
                .build();
        storeHistogram = openTelemetry.getMeter(EasypayServiceApplication.class.getName())
                .histogramBuilder("easypay.payment.store")
                .setDescription("Payment storing time")
                .setUnit("ms")
                .ofLongs()
                .build();
    }
}
```

📝 **3. Record the time** by wrapping both methods in `try-finally`:

```java
private void process(PaymentProcessingContext context) {
    long startTime = System.currentTimeMillis();
    try {
        if (!posValidator.isActive(context.posId)) {
            context.responseCode = PaymentResponseCode.INACTIVE_POS;
            return;
        }
        // ... rest of the original body
    } finally {
        processHistogram.record(System.currentTimeMillis() - startTime);
    }
}

private void store(PaymentProcessingContext context) {
    long startTime = System.currentTimeMillis();
    try {
        Payment payment = new Payment();
        // ... rest of the original body
    } finally {
        storeHistogram.record(System.currentTimeMillis() - startTime);
    }
}
```

📝 **4. Add the counter**:

```java
import io.opentelemetry.api.metrics.LongCounter;

@Service
public class PaymentService {
    // ...
    private LongCounter requestCounter;

    public PaymentService(/* ... */) {
        // ...
        requestCounter = openTelemetry.getMeter(EasypayServiceApplication.class.getName())
                .counterBuilder("easypay.payment.requests")
                .setDescription("Payment requests counter")
                .build();
    }
}
```

And increment it in `accept`:

```java
@Transactional(Transactional.TxType.REQUIRED)
public void accept(PaymentProcessingContext paymentContext) {
    requestCounter.add(1); // < Add this
    process(paymentContext);
    store(paymentContext);
    paymentTracker.track(paymentContext);
}
```

🛠️ **5. Redeploy and generate traffic**:

```powershell
docker compose up -d --build easypay-service
docker compose logs -f easypay-service   # wait for "Started EasypayServiceApplication in ..."
```

Then, in another terminal:

```powershell
k6 run -u 1 -d 1m k6/01-payment-only.js
# without k6:
Send-PaymentBurst -Count 50 -Amount 40000
```

👀 In Grafana → Explore → Prometheus, search `easypay_payment_process`. You get three series:

- `easypay_payment_process_milliseconds_bucket` — count of events faster than the `le` tag,
- `easypay_payment_process_milliseconds_count` — number of hits,
- `easypay_payment_process_milliseconds_sum` — total time.

Average = `sum / count`. Percentiles come from the buckets. The counter appears as
`easypay_payment_requests_total`.

🛠️ **6. Compute percentiles**: select the `_bucket` metric → **Operations** → **Aggregations** →
**Histogram quantile** → pick a quantile → **Run query**.

🛠️ **7. Import the prepared dashboard**: Grafana → **Dashboards** → **New** → **Import**, and paste
the contents of `docker/grafana/dashboards/easypay-monitoring.json` into
*Import via dashboard JSON model*. Select Prometheus as the datasource.

To read the file into your clipboard:

```powershell
Get-Content docker\grafana\dashboards\easypay-monitoring.json -Raw | Set-Clipboard
```

👀 The **Easypay Monitoring** dashboard shows request rate, duration percentiles, and both
histograms' buckets.

🛠️ Generate load to watch it live:

```powershell
k6 run -u 2 -d 2m k6/01-payment-only.js
```

---

## Chapter 4 — Traces

Distributed tracing follows a request across services. The agent is already attached and already
sending traces, so there is nothing to enable in the application.

The collector forwards traces to Tempo: `otlp/tempo: tempo:4317`.

### 4.1 Explore traces

🛠️ Generate traffic:

```powershell
k6 run -u 1 -d 5m k6/01-payment-only.js
```

🛠️ Grafana → **Explore** → **Tempo** datasource → **Run query**.

⚠️ Tempo needs a minute or two to ingest before traces appear. Be patient before concluding it is
broken.

👀 Click **Service Graph** → **Node graph** to see how services talk to each other.

🛠️ Find an interesting trace via the query builder:

- Span Name: `POST easypay-service`
- Duration: `trace` `>` `50ms`
- **Run query**, sort by **Duration**, drill into a `Trace ID`.

👀 In the trace view (widen it via the three dots → **Widen pane**):

- each line is a span,
- SQL queries and their durations are visible,
- transactions are linked across **HTTP** (`api-gateway` → `easypay-service` → `smartbank-gateway`)
  and **Kafka** (`easypay-service` → `fraudetect-service` and `merchant-backoffice`).

🛠️ Enable the graph view: edit the Tempo datasource → **Additional settings** → check
**Enable node graph**. Then reopen a trace and click **Node graph**.

🛠️ Keep exploring: add filter `Status` `=` `error` and hunt down the `NullPointerException` from the
`POS-02` bug.

### 4.2 Sampling

Instrumenting everything also records Prometheus scraping `actuator/health`. In the Service Graph you
will see `User` linked to services other than `api-gateway`, which makes no sense — you only ever
called the gateway.

📝 Add tail sampling to `docker/otelcol/otelcol.yaml`:

```yaml
processors:
  # ...
  tail_sampling/actuator:
      policies:
        [
          {
            name: "filter-http-url",
            type: "string_attribute",
            string_attribute: {
              key: "http.url",
              values: [ "/actuator/health" ],
              enabled_regex_matching: true,
              invert_match: true
            }
          },
          {
            name: "filter-url-path",
            type: "string_attribute",
            string_attribute: {
              key: "url.path",
              values: [ "/actuator/health" ],
              enabled_regex_matching: true,
              invert_match: true
            }
          }
        ]

service:
  pipelines:
    traces:
      receivers: [ otlp ]
      processors: [ batch, tail_sampling/actuator ] # < add it here
      exporters: [ otlp/tempo ]
```

🛠️ Restart the collector:

```powershell
docker compose up -d --build opentelemetry-collector
```

👀 From now on, no more `actuator/health` traces.

### 4.3 Custom spans

⚠️ The workshop text claims `opentelemetry-instrumentation-annotations` is already in
`easypay-service/build.gradle.kts`. It is **not** — only the `opentelemetry-instrumentation-bom` is.
Add the dependency yourself (version comes from that BOM, so no explicit version):

```kotlin
// OpenTelemetry annotations: custom spans (@WithSpan / @SpanAttribute)
implementation("io.opentelemetry.instrumentation:opentelemetry-instrumentation-annotations")
```

📝 Annotate the two methods in `PaymentService`:

```java
import io.opentelemetry.instrumentation.annotations.WithSpan;
import io.opentelemetry.instrumentation.annotations.SpanAttribute;

@Service
public class PaymentService {

    @WithSpan("easypay: Payment processing method")
    private void process(@SpanAttribute("context") PaymentProcessingContext context) {
        // ...
    }

    @WithSpan("easypay: Payment store method")
    private void store(@SpanAttribute("context") PaymentProcessingContext context) {
        // ...
    }
}
```

`@WithSpan` creates a span per invocation; `@SpanAttribute` attaches the whole
`PaymentProcessingContext` to it.

🛠️ Rebuild and test:

```powershell
docker compose up -d --build easypay-service
Send-Payment -Amount 40000
```

👀 Find your new traces in Grafana and observe the two extra spans.

⚠️ Both easypay's re-registration in Eureka and Tempo's ingestion take time. If a trace is missing,
wait rather than re-editing.

---

## Chapter 5 — Correlation

This is where observability pays off: jumping between signals to find a root cause.

### 5.1 Logs → Traces

🛠️ Grafana → **Explore** → **Loki**, filter `service_name` = `easypay-service`, run a query and open
a payment log entry.

👀 Look for `trace_id` and `span_id` attributes (part of the
[W3C Trace Context](https://www.w3.org/TR/trace-context/) spec).

🛠️ Enable the link: **Connections** → **Data sources** → **Loki** → add a **Derived field**:

| Field | Value |
|---|---|
| Name | `TraceID` |
| Type | `Label` |
| Label | `trace_id` |
| Query | `${__value.raw}` |
| URL Label | `View Trace` |
| Internal Link | enabled, datasource `Tempo` |

🛠️ Back in **Explore**, expand a log line → **Fields** / **Links** → click **View Trace**.

👀 Grafana opens the matching Tempo trace.

How it works: the framework puts the trace ID in the MDC so it lands in the log; Grafana's *Derived
fields* parse it back out and bridge to Tempo.

### 5.2 Metrics → Traces (Exemplars)

Exemplars annotate a metric data point with the trace that produced it.

🛠️ Generate load:

```powershell
k6 run -u 1 -d 2m k6/01-payment-only.js
```

In OpenMetrics format an exemplar is the part after the `#`:

```
# {span_id="d0cf53bcde7b60be",trace_id="969873d828346bb616dca9547f0d9fc9"} 0.023276118 1719913187.631
     SPAN ID                    TRACE ID                                    VALUE       TIMESTAMP
```

👀 Inspect them: **Explore** → **Prometheus** → switch to **Code** mode → paste:

```
http_server_request_duration_seconds_bucket{http_route="/payments",service_name="easypay-service"}
```

Unfold **Options**, enable **Exemplars**, **Run query**. Square dots appear at the bottom of the
graph; hover one to see its `trace_id`.

🛠️ Enable the jump: **Connections** → **Data sources** → **Prometheus** → **Exemplars**:

- enable **Internal link**, datasource `Tempo`,
- URL Label: `Go to Trace`,
- Label name: `trace_id`,
- **Save & test**.

🛠️ Hover an exemplar again → **Go to Trace**.

This works because Prometheus runs with `--enable-feature=exemplar-storage` (see
`compose.infrastructure.yml`).

### 5.3 Traces → Logs

🛠️ **Connections** → **Data sources** → **Tempo** → **Trace to logs**:

- Data source: `Loki`
- Span start time shift: `-5m`
- Span end time shift: `5m`
- Tags: `service.name` as `service_name`
- **Filter by trace ID**: enable only if you want strictly matching logs
- **Save & test**

The time shifts exist because log and span timestamps do not match exactly. The tag mapping is
required — it is the bridge between Tempo's `service.name` and Loki's `service_name`.

🛠️ Generate a trace and find it with TraceQL:

```powershell
Send-Payment -Amount 40000
```

In Explore → Tempo, query `{name="POST easypay-service"}` and drill into a trace.

👀 A **LOG** icon appears next to each span — click it for several spans across services.

### 5.4 Traces → Metrics

🛠️ **Connections** → **Data sources** → **Tempo** → **Trace to metrics**:

- Data source: `Prometheus`
- Span start time shift: `-2m`
- Span end time shift: `2m`
- Tags: `service.name` as `service_name`

🛠️ Add two queries (**+ Add query**):

| Link Label | Query |
|---|---|
| `Heap Usage (ratio)` | `sum(jvm_memory_used_bytes{$__tags})/sum(jvm_memory_limit_bytes{$__tags})` |
| `System CPU Usage` | `jvm_cpu_recent_utilization_ratio{$__tags}` |

`$__tags` expands using the **Tags** mapping above.

🛠️ **Save & test**, then find a trace again with `{name="POST easypay-service"}`.

👀 The **LOG** icon is now a link icon offering three choices: `Heap Usage (ratio)`,
`System CPU Usage`, and `Related logs`.

---

## Chapter 6 — Profiling (bonus)

Profiling measures execution time, CPU and memory to find bottlenecks — OpenTelemetry's
[fourth signal](https://opentelemetry.io/blog/2024/profiling/). Grafana Pyroscope stores profiles and
renders them as flamegraphs.

### 6.1 Start Pyroscope

Pyroscope lives in `compose.profiling.yml`, behind a compose profile.

🛠️ Start it:

```powershell
docker compose --profile=profiling up -d
```

✅ A new service listens on port `4040`.

🛠️ Open <http://localhost:4040>. You will see Pyroscope profiling itself, plus a flamegraph. Switch
the signal type (CPU, memory, goroutines) at the top and try the query language.

### 6.2 Instrument easypay for profiling

✅ Both agents are already in the image (from `easypay-service/src/main/docker/Dockerfile`):

```dockerfile
ENV PYROSCOPE_VERSION=v2.0.0
ENV PYROSCOPE_OTEL_VERSION=v1.0.1
ADD --chown=$UID:$GID ${PYROSCOPE_URL} /pyroscope.jar
ADD --chown=$UID:$GID ${PYROSCOPE_OTEL_URL} /pyroscope-otel.jar
```

📝 In `compose.yml`, add the environment and one more agent:

```yaml
services:
  easypay-service:
    # ...
    environment:
      # ...
      PYROSCOPE_APPLICATION_NAME: easypay-service
      PYROSCOPE_FORMAT: jfr
      PYROSCOPE_PROFILING_INTERVAL: 10ms
      PYROSCOPE_PROFILER_EVENT: itimer
      PYROSCOPE_PROFILER_LOCK: 10ms
      PYROSCOPE_PROFILER_ALLOC: 512k
      PYROSCOPE_UPLOAD_INTERVAL: 5s
      OTEL_JAVAAGENT_EXTENSIONS: /pyroscope-otel.jar
      OTEL_PYROSCOPE_ADD_PROFILE_URL: false
      OTEL_PYROSCOPE_ADD_PROFILE_BASELINE_URL: false
      OTEL_PYROSCOPE_START_PROFILING: true
      PYROSCOPE_SERVER_ADDRESS: http://pyroscope:4040
    # ...
    entrypoint:
      - java
      - -javaagent:/pyroscope.jar # < Add
      - -javaagent:/opentelemetry-javaagent.jar
      - -Dotel.instrumentation.logback-appender.experimental-log-attributes=true
      - -Dotel.instrumentation.logback-appender.experimental.capture-mdc-attributes=*
      - -Dotel.metric.export.interval=5000
      - -cp
      - app:app/lib/*
      - com.worldline.easypay.EasypayServiceApplication
```

Notable settings: `PYROSCOPE_FORMAT: jfr` allows multiple event types; `PYROSCOPE_PROFILER_EVENT` may
be `wall`, `itimer` or `cpu`; `OTEL_JAVAAGENT_EXTENSIONS` registers the Pyroscope extension so spans
carry profile context.

The three `OTEL_PYROSCOPE_*` booleans are quoted (`"false"` / `"true"`) in this checkout. Compose
coerces bare YAML booleans to strings anyway, but quoting keeps the intent explicit — `false` in a
Compose `environment:` map is a YAML boolean, not the string the agent reads.

⚠️ Pyroscope only exists under the `profiling` compose profile. Start it ([6.1](#61-start-pyroscope))
*before* redeploying easypay, or the agent logs upload failures against `http://pyroscope:4040`.

🛠️ Redeploy and check:

```powershell
docker compose up -d easypay-service
docker compose logs -f easypay-service
```

👀 You should see Pyroscope lines in the startup logs, and `easypay-service` becomes selectable at
<http://localhost:4040>.

### 6.3 Pyroscope in Grafana

The Pyroscope datasource is already provisioned.

🛠️ Grafana → **Explore** → **Pyroscope**:

- profiling type: `process_cpu` → `cpu`,
- filter: `{service_name="easypay-service"}`,
- then try another type, e.g. memory allocation in TLAB.

🛠️ Generate load:

```powershell
k6 run -u 1 -d 5m k6/02-payment-smartbank.js
```

### 6.4 Traces → Profiles

🛠️ **Connections** → **Data sources** → **Tempo** → **Trace to profiles**:

- Data source: `Pyroscope`
- Tags: `service.name` as `application`
- Profile type: `process_cpu` → `cpu`
- **Save & test**

🛠️ Generate traffic, then in Explore → Tempo query `{name="POST easypay-service"}` and drill into a
trace.

👀 Spans now link to their flamegraph.

---

## Appendix — Troubleshooting

### `/bin/sh: ./gradlew: not found` (exit code 127)

CRLF line endings. See [Chapter 0](#️-the-one-trap-that-will-break-your-build-line-endings).

### Build fails during `docker compose up --build`

All seven service Dockerfiles share a single Gradle cache via
`RUN --mount=type=cache,target=/root/.gradle`, and `--build` builds them in parallel, so they contend
for it.

🛠️ First, get the real error. The default progress output buries it, and piping to `tail` cuts off
the Gradle message entirely:

```powershell
docker compose build --progress=plain <service> *> build.log
Select-String -Path build.log -Pattern "What went wrong" -Context 0,6
```

There are two failure modes, and they need different fixes.

**A. Gradle file-lock timeout** — transient. Build serially, then start:

```powershell
.\scripts\build-services.ps1
docker compose up -d --build
```

**B. Corrupted cache** — persistent:

```text
> Could not read workspace metadata from /root/.gradle/caches/8.7/kotlin-dsl/scripts/<hash>/metadata.bin
```

⚠️ The serial script does **not** fix this one. The corruption is stored inside the cache mount, so
every retry — serial or not — reads the same broken file and fails identically.

🛠️ Purge just that cache entry. Save this as `fixcache.Dockerfile` in any empty directory:

```dockerfile
FROM eclipse-temurin:21-jdk-alpine
RUN --mount=type=cache,target=/root/.gradle \
    rm -rf /root/.gradle/caches/8.7/kotlin-dsl /root/.gradle/caches/8.7/scripts /root/.gradle/caches/8.7/transforms
```

Then:

```powershell
docker build --no-cache -f fixcache.Dockerfile .
docker compose build <service>       # the one that failed
docker compose up -d --remove-orphans
```

This works because the cache mount declares no `id=`, so its id defaults to the target path — any
build claiming `target=/root/.gradle` reaches the same cache. Downloaded dependencies under
`caches/modules-2` survive, so the rebuild is quick.

⚠️ Do **not** reach for `docker builder prune` here. It discards cache mounts for every project on
the machine, not just this one.

🛠️ Check which images actually made it before rebuilding everything:

```powershell
docker images --format "{{.Repository}}:{{.Tag}}" |
    Select-String "^(api-gateway|config-server|discovery-server|easypay-service|fraudetect-service|merchant-backoffice|smartbank-gateway):"
```

Usually only one service lost the race; rebuild that one instead of all seven.

### `easypay-service` returns 503 / is not reachable through the gateway

It has not re-registered with Eureka yet. Check <http://localhost:8761> and wait. Verify health
directly:

```powershell
docker compose ps easypay-service
docker compose logs --tail=50 easypay-service
```

### No data in Grafana

Work down the pipeline:

```powershell
docker compose logs --tail=50 opentelemetry-collector
docker compose ps
```

- No logs in Loki → is the `-javaagent` line actually in your `compose.yml` entrypoint?
- No metrics → did you set `-Dotel.metric.export.interval=5000`, and did you wait 5s?
- No traces → Tempo ingestion lags; wait 1–2 minutes.

### A container is unhealthy after editing `compose.yml`

YAML indentation under `entrypoint:`/`environment:` is unforgiving. Validate the merged config:

```powershell
docker compose config
```

### Grafana or Pyroscope will not start

Their `entrypoint.sh` may have CRLF endings — see Chapter 0. Symptom is an immediately exiting
container:

```powershell
docker compose logs grafana
```

### Port already in use

Find the offender:

```powershell
Get-NetTCPConnection -LocalPort 8080 -State Listen |
    Select-Object LocalPort, OwningProcess,
        @{n='Process';e={(Get-Process -Id $_.OwningProcess).ProcessName}}
```

### Reset everything

```powershell
docker compose down -v --remove-orphans
docker compose up -d --build --remove-orphans
```

⚠️ `-v` drops the database volumes, which resets the seeded POS/card data — including the
deliberately broken `POS-02` row, which will be re-seeded broken from `data.sql`. That is expected.
