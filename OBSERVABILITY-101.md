# Observability 101 — for a junior Java backend developer

Companion to [WINDOWS-GUIDE.md](WINDOWS-GUIDE.md). That file tells you **what to type**. This one
tells you **why any of it is worth doing**, using only the code that is actually in this repository.

Read the first two sections before Chapter 1. Read the rest per chapter — each chapter of the guide
links back here.

---

## Table of contents

1. [Start here: the problem](#start-here-the-problem)
2. [The application in one page](#the-application-in-one-page)
3. [The four signals](#the-four-signals)
4. [Logs](#logs)
5. [Metrics](#metrics)
6. [Traces](#traces)
7. [Correlation](#correlation)
8. [Profiling](#profiling)
9. [How the Java agent works](#how-the-java-agent-works)
10. [Which signal do I reach for](#which-signal-do-i-reach-for)
11. [Glossary](#glossary)
12. [Where each concept appears in the workshop](#where-each-concept-appears-in-the-workshop)

---

## Start here: the problem

Everything you have learned about debugging so far probably assumes three things:

1. The code runs in **one** JVM.
2. You can **attach a debugger** or add a `System.out.println` and re-run.
3. A failure produces **one stack trace** that contains the answer.

This workshop's application breaks all three, and so does every payment platform in production. One
`POST /api/easypay/payments` touches **five Spring Boot services, four PostgreSQL databases and a
Kafka topic**, on someone else's machine, for a request that already finished before anyone noticed
it was wrong.

Concretely, three failures in this repo cannot be diagnosed the way you diagnose a monolith:

| Failure | Why the monolith habit fails |
| --- | --- |
| A payment comes back `AMOUNT_EXCEEDED` | Nothing is broken in easypay. `smartbank-gateway` is unreachable and easypay silently downgraded to a fallback decision. The stack trace you want is in **another service** — and there is no exception at all in this one. |
| `POS-02` returns HTTP 500 | The `NullPointerException` names `PosValidator.isActive`, but not *which* POS, and not *which customer*. Under load, a hundred interleaved requests produce a hundred identical traces. |
| `smartbank-gateway` dies of `OutOfMemoryError` | It happens after minutes of sustained traffic. There is no single request to debug: the evidence is a **trend**, not an event. |

Observability is the practice of making a running system explain itself well enough that you can
answer *new* questions about it — including questions nobody thought of when the code was written —
**without redeploying**. That last part is the whole point. In production you cannot add a
`println` and try again.

One more thing, and it is the single most convincing fact in this workshop:

> Every refused payment in this application returns **HTTP 201 Created**. `PaymentResource.processPayment()`
> ends with `ResponseEntity.created(location).body(response)`, and the refusal is a `responseCode`
> field *inside the body*. Only the `POS-02` crash returns a 500.

So a monitor watching HTTP status codes reports **100% success** while every customer is being
refused. Technical health and business health are not the same signal. That is why
[Chapter 3.5](WINDOWS-GUIDE.md#35-business-metrics) exists.

---

## The application in one page

```text
                          ┌─────────────────┐
   Send-Payment  ──POST──▶│   api-gateway   │  :8080  (the only public port)
                          └────────┬────────┘
                                   │  /api/easypay/**  ──▶ http://easypay-service:8080
                                   ▼
                   ┌───────────────────────────────┐
                   │        easypay-service        │──▶ postgres-easypay :5432
                   │                               │
                   │ PaymentResource               │
                   │   └▶ PaymentService.accept()  │
                   │        ├▶ PosValidator        │  DB lookup, POS active?
                   │        ├▶ CardValidator       │  Luhn, card type, blacklist
                   │        ├▶ BankAuthorService   │──▶ smartbank-gateway  (amount > 10000)
                   │        ├▶ PaymentRepository   │  persist
                   │        └▶ PaymentTracker      │──▶ Kafka payment-topic
                   └───────────────────────────────┘
                                   │
                    ┌──────────────┴──────────────┐
                    ▼                             ▼
           fraudetect-service           merchant-backoffice
           (group: fraudetect)          (group: merchant-bo)
```

The numbers that decide which path a request takes — all of them real, all of them in the code:

| Setting | Value | Where | Effect |
| --- | --- | --- | --- |
| `payment.author.threshold` | `10000` | `PaymentService` | above it, easypay calls the bank; at or below, it never does (**no multi-service trace**) |
| `smartbank.bankauthor.validation.maxAmount` | `40000` | `AuthorizationService` | bank authorizes `<= 40000`, denies above → `AUTHORIZATION_DENIED` |
| `payment.max.amount.fallback` | `20000` | `BankAuthorService` | used **only** when the bank is unreachable: below it the payment is accepted by delegation, above it → `AMOUNT_EXCEEDED` |
| `@Retry(name = "BankAuthorService")` | 3 attempts, 1s, ×2 backoff | `application.yaml` | three failed calls before the fallback runs — so one customer request can mean **three** outbound calls |

Read that last row again: a single user request can become three bank calls plus a fallback. When
`smartbank-gateway` is slow, easypay's latency triples for reasons that are invisible in easypay's
own code. Traces are how you see it.

The seed data is deliberately imperfect (`easypay-service/src/main/resources/db/postgresql/data.sql`):

| POS | `active` | Result |
| --- | --- | --- |
| `POS-01` | `true` | normal path |
| `POS-02` | `NULL` | `NullPointerException` → HTTP 500 (the teaching bug) |
| `POS-03` | `false` | `INACTIVE_POS` → HTTP 201, handled cleanly |
| `POS-04` | `true` | normal path |

`POS-02` vs `POS-03` is the cleanest lesson in the repo: **same business outcome, opposite
engineering meaning.** One is a rule, one is a defect. No metric distinguishes them; a log line does.

---

## The four signals

| Signal | Answers | Shape | Cost | Backend here |
| --- | --- | --- | --- | --- |
| **Logs** | "what happened in *this* request, and why" | discrete events, text or JSON | high per event | Loki :3100 |
| **Metrics** | "how is the system *right now* / over time" | numbers aggregated over time | very low, fixed | Prometheus :9090 |
| **Traces** | "where did *this* request spend its time, across services" | tree of timed spans | medium, usually sampled | Tempo :3200 |
| **Profiles** | "which *lines of code* burned the CPU" | stack samples | medium, continuous | Pyroscope :4040 |

The mental model that makes this stick:

- A **metric** tells you something is wrong. ("p99 latency doubled.")
- A **trace** tells you *where*. ("The bank call takes 3s and is retried twice.")
- A **log** tells you *why*. ("Connection refused to smartbank-gateway; accepted by delegation.")
- A **profile** tells you *which code*. ("`Hazelcast.get` is 60% of CPU.")

You need all four because each one is cheap at answering its own question and terrible at answering
the others. Counting payments by reading log lines is absurdly expensive; asking a metric which
customer was affected is impossible — the customer id is not in there, and putting it there would
destroy the metric (see [cardinality](#cardinality)).

In this workshop all four travel the same road:

```text
your service  ──OTLP──▶  OpenTelemetry Collector  ──┬──▶ Loki        (logs)
 (Java agent)             :4317 gRPC / :4318 HTTP   ├──▶ Prometheus  (metrics)
                                                    └──▶ Tempo       (traces)
                          Pyroscope is written to directly by the pyroscope agent
```

One protocol (OTLP), one collector, four stores, one UI (Grafana :3000). The collector is where you
can transform data *without touching the application* — which is exactly what
[2.8](WINDOWS-GUIDE.md#28-pii-obfuscation) and [4.2](WINDOWS-GUIDE.md#42-sampling) do.

---

## Logs

### Levels

| Level | Use for | In this app |
| --- | --- | --- |
| `TRACE` | fine-grained diagnostics | unused |
| `DEBUG` | program state during development | `LOG.debug("Response: found payment: {}", …)` |
| `INFO` | normal, notable operations | `LOG.info("Processing new payment: {}", …)` |
| `WARN` | something is off but handled | `LOG.warn("Check POS does not pass: inactive posId {}", …)` |
| `ERROR` | unexpected failure needing attention | `LOG.error(e.getMessage())` |

The rule juniors get wrong: **level is about the reader, not about your feelings.** `WARN` means "a
human should look at this eventually". If everything is `INFO`, nothing is.

Always use placeholders, never concatenation:

```java
LOG.info("Processing payment {} for POS {}", paymentId, posId);   // yes
LOG.info("Processing payment " + paymentId + " for POS " + posId); // no — builds the string even when the level is off
```

`PaymentService` actually contains one of the bad ones (`LOG.info("Authorization refused by bank,
context=" + context)`). Real code has warts; now you can spot them.

### Structured logging

A log line is text. A *structured* log line is a record with fields:

```text
2024-07-02 09:12:41  INFO  Processing new payment: PaymentRequest{posId='POS-02', ...}
```

versus

```json
{"timestamp":"...","level":"INFO","message":"Processing new payment","pos":"POS-02","trace_id":"a1b2..."}
```

The second one is *queryable*: `{service_name="easypay-service"} | pos="POS-02"`. The first one is a
regex problem. This is the entire reason Loki, Elasticsearch and friends exist, and why
[2.5](WINDOWS-GUIDE.md#25-structured-logging-optional) offers `ecs` / `gelf` / `logstash` formats.

You do not have to choose in this workshop: the OpenTelemetry agent ships your normal Logback output
to the collector **as structured records**, adding `service_name`, `trace_id` and `span_id` for free.

### MDC

**MDC = Mapped Diagnostic Context**: a `Map<String,String>` attached to the *current thread*, provided
by SLF4J. Put values in once, and every log line from that thread can print them.

```java
MDC.put("cardNumber", paymentRequest.cardNumber());
MDC.put("pos", paymentRequest.posId());
try {
    // ... the whole request
} finally {
    MDC.clear();          // NOT optional
}
```

Two things a junior must internalize here:

1. **Why it exists.** Tomcat handles requests concurrently. Without MDC, ten interleaved requests
   produce ten interleaved log lines and you cannot tell which POS caused which error. With MDC,
   every line carries its own request's identity. That is the exercise in
   [2.3 → 2.4](WINDOWS-GUIDE.md#24-mapped-diagnostic-context-mdc): run k6, watch the logs become
   unreadable, then add MDC and watch them become readable again.
2. **Why `MDC.clear()` in a `finally`.** The thread comes from a **pool**. It will serve another
   customer next. A forgotten `clear()` means request B's log lines carry request A's card number —
   a data leak produced by a missing line of cleanup, and a bug that only appears under
   concurrency.

The printing side is a Logback pattern, configured in `application.yaml`:

```yaml
logging:
  pattern:
    level: "%5p [%mdc]"                            # the whole map
    # level: "%5p [%X{cardNumber} - %X{pos}]"      # specific keys
```

MDC is also the bridge to tracing: the agent puts `trace_id` into the MDC, which is what makes
[5.1 Logs → Traces](WINDOWS-GUIDE.md#51-logs--traces) work at all.

### PII

`cardNumber` is a **Primary Account Number**. Putting a PAN in a log store is a PCI-DSS violation,
and "we'll delete it later" is not a control. In this repo the leak is subtle and worth tracing
carefully:

- `PaymentRequest.toString()` already prints `cardNumber='****'` — so `LOG.info("Processing new
  payment: {}", paymentRequest)` is **safe**.
- `MDC.put("cardNumber", …)` stores the **raw** value, and `%mdc` prints the whole map — so the PAN
  reaches stdout, and `docker compose logs easypay-service` shows it.
- The collector's `redaction/card-numbers` processor rewrites it to `****` before Loki
  ([2.8](WINDOWS-GUIDE.md#28-pii-obfuscation)).

So there are two independent places to fix it: **in the app** (never log it) and **in the pipeline**
(never store it). The collector protects the backend, not your terminal. Defence in depth means both.

---

## Metrics

### Counter, gauge, histogram

| Instrument | Meaning | Rule of thumb | Example here |
| --- | --- | --- | --- |
| **Counter** | monotonically increasing total | always ask for its *rate*, never its value | `easypay.payment.requests` |
| **Gauge** | current value, up and down | sample of "now" | `jvm_memory_used_bytes` |
| **Histogram** | distribution of values in buckets | for anything time-shaped | `easypay.payment.process` (ms) |

A counter's absolute value is meaningless ("47,201 payments since some restart"); the interesting
form is `rate(easypay_payment_requests_total[5m])`. Prometheus adds `_total` to counters and a unit
suffix to everything, which is why the code declares `easypay.payment.process` and you query
`easypay_payment_process_milliseconds_bucket`. Dots become underscores; the unit (`ms`) becomes
`_milliseconds`.

### Why not averages

An average latency of 200ms is compatible with "everything takes 200ms" *and* with "95% take 50ms
and 5% take 3 seconds". The second one is an outage for one customer in twenty; the average hides it.

A histogram counts observations into buckets:

```text
easypay_payment_process_milliseconds_bucket{le="50"}   1400   # ≤ 50ms
easypay_payment_process_milliseconds_bucket{le="100"}  1480   # ≤ 100ms
easypay_payment_process_milliseconds_bucket{le="+Inf"} 1500   # everything
easypay_payment_process_milliseconds_count             1500
easypay_payment_process_milliseconds_sum             182000
```

From that you get quantiles (`histogram_quantile(0.99, …)` — the p99), and `sum / count` if you still
want the average. You cannot go the other way: an average cannot be turned back into a p99. **Record
histograms, derive averages.** That is why [3.5](WINDOWS-GUIDE.md#35-business-metrics) uses
`LongHistogram` for `process` and `store`, and a plain counter only for the request count.

### Cardinality

Every distinct combination of label values is a separate time series stored forever.

```java
requestCounter.add(1);                                          // 1 series — fine
requestCounter.add(1, Attributes.of(POS_ID, context.posId));     // 4 series (4 POS) — fine
requestCounter.add(1, Attributes.of(CARD, context.cardNumber));  // one series PER CARD — never do this
```

Unbounded label values (card number, payment id, user id, URL with an id in it) are the classic way
juniors take down a Prometheus. The limit is not politeness, it is memory. **Rule: a label's value
set must be small, known and bounded.** High-cardinality identity belongs in logs and traces, which
are stored per event and indexed differently.

This is also the answer to "why not just put everything in metrics": you cannot, and the reason is
arithmetic.

### Export interval

The agent batches metrics and ships them every **60s** by default. A workshop where nothing appears
for a minute is unusable, hence
[3.1](WINDOWS-GUIDE.md#31-speed-up-the-export-interval): `-Dotel.metric.export.interval=5000`.

Note the pattern — **every agent system property has an environment-variable twin**:
`otel.metric.export.interval` ⇄ `OTEL_METRIC_EXPORT_INTERVAL`. In production you tune the interval
up, not down: it is a direct trade of freshness against network and storage cost.

---

## Traces

### Span and trace

A **span** is one timed operation with a name, a start, a duration, attributes and a parent. A
**trace** is the tree of spans belonging to one logical request.

For a `40000` payment in this app, the trace looks roughly like:

```text
POST /api/easypay/payments                       api-gateway        820ms
└── POST /payments                               easypay-service    780ms
    ├── SELECT easypay.pos_ref                   easypay-service      4ms
    ├── SELECT easypay.card_ref                  easypay-service      3ms
    ├── POST /authors/authorize                  smartbank-gateway  600ms
    │   └── INSERT smartbank.bank_author         smartbank-gateway   12ms
    ├── INSERT easypay.payment                   easypay-service      6ms
    └── payment-topic publish                    easypay-service      2ms
        ├── payment-topic receive                fraudetect-service  30ms
        └── payment-topic receive                merchant-backoffice 25ms
```

Nobody wrote code to produce that. The agent instruments Spring MVC, JDBC, Feign and Kafka clients
automatically. What you *do* add by hand
([4.3](WINDOWS-GUIDE.md#43-custom-spans)) is the **business** structure the agent cannot guess:

```java
@WithSpan("easypay: Payment processing method")
private void process(@SpanAttribute("context") PaymentProcessingContext context) { … }
```

`@WithSpan` creates a child span per invocation; `@SpanAttribute` attaches an argument to it. Now
"time spent validating" is visible as its own bar instead of being lumped into the HTTP span.

### Context propagation

The magic word is **propagation**. When easypay calls smartbank over HTTP, the agent adds a header:

```text
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             ^^ ^--------- trace id ---------^ ^-- parent span --^ ^^ flags
```

defined by [W3C Trace Context](https://www.w3.org/TR/trace-context/). smartbank's agent reads it and
makes its spans children of yours. The same happens through **Kafka message headers**, which is why
`fraudetect-service` shows up in the same trace even though it consumes asynchronously, minutes of
architecture away from the HTTP request.

Break propagation — a thread pool that does not copy context, a manually built HTTP client, a queue
that drops headers — and you get two unrelated half-traces. That is the most common real-world
tracing bug, and now you know what to look for.

### Sampling

Tracing every request is expensive, and most traces are boring. Two strategies:

- **Head sampling** — decide at the start (e.g. keep 10%). Cheap, but you may throw away the one
  slow request you cared about.
- **Tail sampling** — buffer the whole trace, then decide, using what happened. Expensive, but you
  can say "keep everything with an error, and 1% of the rest".

[4.2](WINDOWS-GUIDE.md#42-sampling) uses a tail-sampling policy in the collector to drop
`/actuator/health` traces. Why it matters conceptually: Prometheus scrapes health endpoints
constantly, so without that filter the Service Graph shows `User` talking to services you never
called — noise that makes the picture *lie*. Filtering telemetry is part of instrumenting it.

---

## Correlation

Three signals in three browser tabs is not observability. The value is the **jump**: a graph spike →
the exact trace → that request's logs → the CPU profile of the slow method. This is
[Chapter 5](WINDOWS-GUIDE.md#chapter-5--correlation), and it is pure Grafana configuration — no code
at all.

| Jump | Mechanism | Why it works |
| --- | --- | --- |
| Logs → Traces | Loki **derived field** on `trace_id` → Tempo | the agent put `trace_id` in the MDC, so it is in the log record |
| Metrics → Traces | Prometheus **exemplars** | a histogram bucket keeps a sample `trace_id` alongside the number (needs `--enable-feature=exemplar-storage`) |
| Traces → Logs | Tempo **trace to logs**, tag `service.name` → `service_name` | Tempo and Loki name the same thing differently; the mapping is the bridge |
| Traces → Metrics | Tempo **trace to metrics**, `$__tags` | expands the same tag mapping into a PromQL query |

An **exemplar** is worth stating plainly, because it is the least obvious idea in the workshop: it is
a single concrete example attached to an aggregate. "p99 was 3s — and here is one actual request that
took 3s." Aggregate *and* instance, in one click. In OpenMetrics text it is the part after the `#`:

```text
# {span_id="d0cf53bcde7b60be",trace_id="969873d828346bb616dca9547f0d9fc9"} 0.023276118 1719913187.631
```

The recurring theme: correlation is not a feature you install, it is a consequence of **carrying the
same identifiers everywhere**. `trace_id` in logs, `trace_id` in exemplars, `service.name` in both
naming schemes. Do that, and the tools link themselves.

---

## Profiling

Traces tell you *which method* was slow. Profiles tell you *which lines burned the CPU inside it*.

**Continuous profiling** means sampling stack traces of the running process constantly (here every
`10ms`, uploaded every `5s`) and aggregating them into a **flamegraph**: width = share of samples =
share of CPU. It is a profiler you leave switched on in production, which is what makes it a
telemetry signal rather than a development tool.

OpenTelemetry calls profiling the [fourth signal](https://opentelemetry.io/blog/2024/profiling/).
Two agents cooperate in [6.2](WINDOWS-GUIDE.md#62-instrument-easypay-for-profiling):

- `-javaagent:/pyroscope.jar` — the profiler itself, configured entirely through `PYROSCOPE_*` env
  vars.
- `OTEL_JAVAAGENT_EXTENSIONS=/pyroscope-otel.jar` — an extension **to the OTel agent** that stamps
  span context onto profile samples. That is what makes span → flamegraph possible.

Use it when a trace says "600ms inside one method" and you need to know whether that is JSON
serialization, a cache lookup, or GC pressure. Which is exactly the `smartbank-gateway` story: it
runs Hazelcast with `-Xmx2g` and dies under `k6/02-payment-smartbank.js`.

---

## How the Java agent works

You add **one JVM flag** and get logs, metrics and traces for Spring MVC, JDBC, Feign, Kafka and the
JVM itself, without touching a single line of application code. That deserves an explanation, because
"it's magic" is a bad place to leave it.

```text
- java
- -javaagent:/opentelemetry-javaagent.jar    # ← this
- -Dotel.instrumentation.logback-appender.experimental-log-attributes=true
- -Dotel.metric.export.interval=5000
- -cp
- app:app/lib/*
- com.worldline.easypay.EasypayServiceApplication
```

What happens, in order:

1. Before `main()` runs, the JVM hands the agent a `premain` hook and an `Instrumentation` object.
2. The agent registers a **bytecode transformer**. As each class loads, it matches known library
   signatures (`DispatcherServlet`, `Connection.prepareStatement`, Feign clients, Kafka consumers)
   and rewrites the loaded bytes to wrap those methods with span start/stop, metric recording and
   context propagation.
3. Your `.class` files on disk are untouched. Your source is untouched. The *loaded* classes differ.

Consequences worth knowing:

- **Instrumentation is library-shaped, not code-shaped.** The agent knows Spring MVC; it does not
  know what a "payment" is. Business meaning is the part you add by hand — that is precisely what
  [3.5](WINDOWS-GUIDE.md#35-business-metrics) and [4.3](WINDOWS-GUIDE.md#43-custom-spans) are for.
- **Order matters** when you stack agents: `-javaagent:/pyroscope.jar` is listed *before* the OTel
  agent in `compose.yml`.
- **Configuration is env-var-first**, which is why the whole thing is tunable from `compose.yml`
  with no rebuild: `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_RESOURCE_ATTRIBUTES`,
  `OTEL_METRIC_EXPORT_INTERVAL`.
- `OTEL_RESOURCE_ATTRIBUTES` is how a signal gets its identity — `service.name=easypay-service` is
  what later becomes the `service_name` label you filter on in Loki, Prometheus and Tempo. Get it
  wrong and your data is there but unfindable.

In this repo every service **except** easypay already runs with the agent. Adding it to easypay is
[2.6](WINDOWS-GUIDE.md#26-attach-the-opentelemetry-java-agent) — the moment where a blind service
becomes visible, which is the most satisfying twenty seconds of the workshop.

---

## Which signal do I reach for

Practise on this repo's own incidents:

| Symptom | Start with | Then | Why that order |
| --- | --- | --- | --- |
| "Customers get `AMOUNT_EXCEEDED`" | **logs** (`WARN` from `BankAuthorService`) | **trace** to see the failed bank call and retries | the code is fine; a dependency is not, and only the trace shows the retry storm |
| "`POS-02` returns 500" | **logs** with MDC | trace filtered on `Status = error` | you need the *identity* (which POS) — that is log/trace territory, never metrics |
| "Payments are slower since Tuesday" | **metrics** (p99 histogram) | exemplar → one slow trace | a trend is a metric question; a metric cannot name a request, so jump via exemplar |
| "`smartbank-gateway` keeps restarting" | **metrics** (JVM heap, GC) | logs → `OutOfMemoryError` | resource exhaustion is a trend, and the log confirms the cause |
| "This method is 600ms and I don't know why" | **profile** (flamegraph) | — | line-level CPU attribution exists nowhere else |
| "Did payment `3cd8df14…` succeed?" | **logs** / trace by id | — | single-entity question; metrics are aggregates by construction |

The meta-rule: **aggregate questions → metrics. Single-request questions → traces and logs.
Code-level questions → profiles.** Reaching for the wrong one is the most common time sink in an
incident.

---

## Glossary

| Term | Plain meaning |
| --- | --- |
| **OTLP** | OpenTelemetry Protocol — the wire format all four signals use here (gRPC :4317, HTTP :4318) |
| **Collector** | a process that receives, transforms and forwards telemetry, so the app does not have to know about backends |
| **Pipeline** | receivers → processors → exporters, defined per signal in `docker/otelcol/otelcol.yaml` |
| **Instrumentation** | code that emits telemetry; *auto* = added by the agent, *manual* = written by you |
| **Span** | one timed operation inside a trace |
| **Trace id / span id** | 16-byte / 8-byte ids identifying a trace and one span in it |
| **Propagation** | passing trace ids to the next service (HTTP `traceparent`, Kafka headers) |
| **Sampling** | keeping a subset of traces; head = decide early, tail = decide after buffering |
| **MDC** | SLF4J's per-thread map of key/values that log patterns can print |
| **Cardinality** | number of distinct label-value combinations = number of stored time series |
| **Bucket** | histogram counter of observations `≤ le` |
| **Quantile / p99** | value below which 99% of observations fall |
| **Exemplar** | a sample `trace_id` attached to a metric data point |
| **Resource attributes** | identity of the telemetry producer (`service.name`, `service.version`, …) |
| **Flamegraph** | stacked bars where width = share of CPU samples |
| **Derived field** | Grafana Loki feature extracting a value from a log line and linking it elsewhere |

---

## Where each concept appears in the workshop

| Guide chapter | Concepts you meet | Read first |
| --- | --- | --- |
| [Chapter 0](WINDOWS-GUIDE.md#chapter-0--setup-read-this-first) | none — tooling and the CRLF trap | — |
| [Chapter 1](WINDOWS-GUIDE.md#chapter-1--start-the-infrastructure) | the distributed request path | [The application in one page](#the-application-in-one-page) |
| [Chapter 2](WINDOWS-GUIDE.md#chapter-2--logs) | log levels, structured logs, MDC, PII, the Java agent | [Logs](#logs), [How the Java agent works](#how-the-java-agent-works) |
| [Chapter 3](WINDOWS-GUIDE.md#chapter-3--metrics) | counters, gauges, histograms, quantiles, cardinality | [Metrics](#metrics) |
| [Chapter 4](WINDOWS-GUIDE.md#chapter-4--traces) | spans, propagation, sampling, span attributes | [Traces](#traces) |
| [Chapter 5](WINDOWS-GUIDE.md#chapter-5--correlation) | derived fields, exemplars, tag mapping | [Correlation](#correlation) |
| [Chapter 6](WINDOWS-GUIDE.md#chapter-6--profiling-bonus) | continuous profiling, flamegraphs | [Profiling](#profiling) |

If you remember one sentence from all of this: **you are not adding logging, you are making the
system able to answer questions you have not thought of yet.**
