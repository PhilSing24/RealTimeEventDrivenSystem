# ADR-002: Feed Handler to kdb Ingestion Path

## Status
Accepted

## Date
2025-12-17

## Context

This project ingests real-time Binance market data via WebSocket in a C++ feed handler and publishes it into a kdb+/KDB-X environment for real-time analytics.

There are multiple technically valid ingestion paths from an external feed handler into kdb, including:

- Direct publication into a Tickerplant via IPC
- Writing to intermediate logs or files for later ingestion
- Embedding q/kdb within the feed handler process
- Publishing directly into an RDB
- Using alternative transports (message queues, streaming platforms, etc.)

Each option represents different trade-offs in terms of latency, complexity, observability, resilience, and alignment with established kdb architectures.

This project is explicitly inspired by the *Building Real Time Event Driven KDB-X Systems* reference architecture, which assumes a tickerplant-centric design.

## Notation

| Acronym | Definition |
|---------|------------|
| FH | Feed Handler |
| IPC | Inter-Process Communication |
| RDB | Real-Time Database |
| TP | Tickerplant |

## Decision

The feed handler will publish data **directly into a Tickerplant via IPC**.

### Ingestion Path

- The C++ feed handler connects to a running kdb tickerplant using the kdb+ C API.
- Each normalised trade event is published as an update message to the tickerplant.
- The tickerplant remains the single ingress point for:
  - Logging (if enabled, see ADR-003)
  - Fan-out to RDB(s)
  - Time-ordering and sequencing
- The feed handler remains stateless with respect to downstream consumers.

### IPC Mode

The feed handler uses **asynchronous IPC** to publish updates to the tickerplant.

In kdb+ terms, this is equivalent to using `neg[h](...)` rather than `h(...)`.

Rationale:
- Minimises feed handler blocking
- Reduces end-to-end latency
- Aligns with standard kdb real-time patterns

Trade-off: Asynchronous publishing means the feed handler cannot confirm successful receipt. This is acceptable because:
- ADR-003 defers durability to future work
- Upstream replay (Binance reconnect) provides recovery

### Publishing Mode

The feed handler publishes **tick-by-tick** (one IPC call per trade event).

Rationale:
- Simplifies latency measurement (no batching delays)
- Provides clearest view of per-event latency characteristics
- Appropriate for initial exploratory phase
- Matches the "hot path" pattern from the reference architecture

Trade-off: Tick-by-tick publishing has higher IPC overhead than batching. This is acceptable because:
- Latency measurement clarity is prioritised over throughput
- Binance trade rates are manageable without batching
- Batching can be introduced later if throughput becomes a concern

### Message Format

Each normalised trade is published as a kdb+ IPC message using native serialisation.

On the tickerplant side:
- Messages are received via `.z.ps` (async) handler
- The standard `upd` function is invoked with table name and row data

Example (conceptual kdb+ equivalent):
```q
neg[h] (`.u.upd; `trade_binance; tradeData)
```

### Connection Failure Handling

If the connection to the tickerplant is lost:
- The feed handler logs an error
- Incoming messages are dropped (not buffered)
- The feed handler attempts to reconnect with backoff
- Recovery relies on Binance WebSocket reconnection semantics

This fail-fast approach is acceptable given the project's exploratory nature (see ADR-006).

Future enhancement: A local recovery buffer or log could be introduced if durability guarantees are required (see ADR-003 for logging strategy).

## Rationale

This option was selected because it:

- Aligns with canonical kdb real-time architectures.
- Preserves a clear separation of concerns:
  - Feed handler: external I/O, parsing, normalisation, timestamp capture (see ADR-001)
  - Tickerplant: sequencing, publication, durability boundary
  - RDB: query consistency and real-time analytics
- Minimises end-to-end latency by avoiding intermediate persistence layers.
- Keeps operational complexity low for an exploratory but realistic system.
- Allows later evolution (e.g., replication, logging, recovery) without changing the feed handler contract.

## Alternatives Considered

### 1. Writing to Files or Logs
Rejected because:
- Adds latency and operational overhead.
- Duplicates functionality already handled by the tickerplant.
- Moves the system away from event-driven design.

### 2. Embedding q inside the Feed Handler
Rejected because:
- Couples C++ lifecycle and kdb runtime tightly.
- Complicates deployment and debugging.
- Reduces architectural clarity.

### 3. Publishing Directly to an RDB
Rejected because:
- Bypasses the tickerplant's role in sequencing and fan-out.
- Makes scaling and recovery more difficult.
- Deviates from standard kdb design patterns.

### 4. Using External Messaging Systems
Out of scope for this project:
- Introduces unnecessary infrastructure.
- Distracts from core kdb architecture exploration.

### 5. Synchronous IPC
Rejected because:
- Blocks the feed handler until the tickerplant acknowledges
- Increases end-to-end latency
- Not necessary given current durability stance (ADR-003)

### 6. Batched Publishing
Rejected because:
- Introduces batching delay into latency measurements
- Complicates per-event latency analysis
- Not required at current message rates

May be reconsidered if throughput requirements increase.

## Consequences

### Positive

- Clean, canonical ingestion pipeline.
- Clear ownership boundaries between components.
- Easy to reason about latency and ordering.
- Feed handler remains simple and testable.
- Tick-by-tick publishing provides clear latency visibility.
- Asynchronous IPC minimises feed handler blocking.

### Negative / Trade-offs

- Requires a running tickerplant for ingestion.
- Recovery and replay are delegated to upstream sources or TP design.
- Feed handler cannot independently guarantee durability.
- Asynchronous publishing means no delivery confirmation.
- Tick-by-tick has higher IPC overhead than batching.
- Messages are lost if connection drops (no local buffering).

These trade-offs are acceptable and consistent with the project's goals.

## Links / References

- `../kdbx-real-time-architecture-reference.md`
- `../kdbx-real-time-architecture-measurement-notes.md`
- `adr-001-timestamps-and-latency-measurement.md` (timestamp capture in FH)
- `adr-003-tickerplant-logging-and-durability-strategy.md` (logging and durability)
- `adr-006-recovery-and-replay-strategy.md` (recovery deferral)