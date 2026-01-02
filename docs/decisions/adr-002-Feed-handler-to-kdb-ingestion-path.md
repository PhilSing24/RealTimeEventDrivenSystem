# ADR-002: Feed Handler to kdb Ingestion Path

## Status
Accepted (Updated 2025-12-29)

## Date
2025-12-17 (Updated 2025-12-29)

## Context

This project ingests real-time Binance market data via WebSocket in C++ feed handlers and publishes it into a kdb+/KDB-X environment for real-time analytics.

Two data types are ingested:
- **Trade data** — Individual trade executions from the trade stream
- **Quote data** — Best bid/ask (L1) derived from order book depth stream

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
| RTE | Real-Time Engine |
| TP | Tickerplant |

## Decision

Both feed handlers publish data **directly into a single Tickerplant via IPC**.

### Architecture

```
Binance Trade Stream ──► Trade FH ──┬──► TP:5010 ──┬──► RDB (trades)
                                    │              ├──► RTE (trades)
Binance Depth Stream ──► Quote FH ──┘              └──► Logs (both)
```

### Feed Handler Design

| Handler | Data Type | State | Source |
|---------|-----------|-------|--------|
| Trade FH | `trade_binance` | Stateless | WebSocket trade stream |
| Quote FH | `quote_binance` | Stateful (order book) | WebSocket depth + REST snapshot |

**Separate processes**: Each feed handler runs as an independent process. This follows the "single responsibility" principle and provides:
- Independent failure domains
- Simpler code (no threading)
- Independent restart capability

### Trade Feed Handler

The trade feed handler is **stateless**:
- Receives trade events from Binance WebSocket
- Parses JSON, normalises fields
- Publishes immediately to tickerplant
- No internal state maintained

### Quote Feed Handler

The quote feed handler is **stateful** (see ADR-009):
- Maintains order book state per symbol
- Fetches REST snapshot for initial sync
- Applies WebSocket depth deltas
- Validates sequence numbers
- Publishes L1 (best bid/ask) on change or timeout
- Tracks validity state (INIT → SYNCING → VALID ↔ INVALID)

### Ingestion Path

- Each C++ feed handler connects to the running kdb tickerplant using the kdb+ C API
- Normalised events are published as update messages to the tickerplant
- The tickerplant remains the single ingress point for:
  - Logging (separate files per data type, see ADR-003)
  - Fan-out to subscribers (RDB, RTE)
  - Time-ordering and sequencing

### IPC Mode

Both feed handlers use **asynchronous IPC** to publish updates to the tickerplant.

In kdb+ terms, this is equivalent to using `neg[h](...)` rather than `h(...)`.

Rationale:
- Minimises feed handler blocking
- Reduces end-to-end latency
- Aligns with standard kdb real-time patterns

Trade-off: Asynchronous publishing means the feed handler cannot confirm successful receipt. This is acceptable because:
- TP logging provides durability (ADR-003)
- Upstream replay (Binance reconnect) provides recovery for gaps

### Publishing Mode

Both feed handlers publish **tick-by-tick** (one IPC call per event).

| Handler | Trigger |
|---------|---------|
| Trade FH | Every trade received |
| Quote FH | L1 change or 50ms timeout |

Rationale:
- Simplifies latency measurement (no batching delays)
- Provides clearest view of per-event latency characteristics
- Appropriate for initial exploratory phase
- Matches the "hot path" pattern from the reference architecture

Trade-off: Tick-by-tick publishing has higher IPC overhead than batching. This is acceptable because:
- Latency measurement clarity is prioritised over throughput
- Current message rates are manageable without batching
- Batching can be introduced later if throughput becomes a concern

### Message Format

Each normalised event is published as a kdb+ IPC message using native serialisation.

On the tickerplant side:
- Messages are received via `.z.ps` (async) handler
- The standard `upd` function is invoked with table name and row data

Examples (conceptual kdb+ equivalent):
```q
/ Trade publication
neg[h] (`.u.upd; `trade_binance; tradeData)

/ Quote publication
neg[h] (`.u.upd; `quote_binance; quoteData)
```

### Tables Published

| Table | Source | Fields | Subscribers |
|-------|--------|--------|-------------|
| `trade_binance` | Trade FH | 14 fields (see schema spec) | RDB, RTE |
| `quote_binance` | Quote FH | 11 fields (see ADR-009) | RDB |

### Connection Failure Handling

If the connection to the tickerplant is lost:
- The feed handler logs an error
- Incoming messages are dropped (not buffered)
- The feed handler attempts to reconnect with backoff
- Recovery relies on Binance WebSocket reconnection semantics

For the quote handler specifically:
- Order book state is preserved during TP disconnect
- Publications resume when connection restored
- Book validity is maintained independently of TP connection

This fail-fast approach is acceptable given the project's exploratory nature (see ADR-006).

## Rationale

This option was selected because it:

- Aligns with canonical kdb real-time architectures
- Preserves a clear separation of concerns:
  - Feed handlers: external I/O, parsing, normalisation, timestamp capture (ADR-001)
  - Tickerplant: sequencing, publication, logging (ADR-003)
  - RDB: storage and query consistency
  - RTE: derived analytics (ADR-004)
- Minimises end-to-end latency by avoiding intermediate persistence layers
- Keeps operational complexity low for an exploratory but realistic system
- Allows later evolution (e.g., replication, recovery) without changing the feed handler contract

### Separate Processes Rationale

Running trade and quote handlers as separate processes was selected because:
- Simpler than multi-threaded single process
- Independent failure domains (quote crash doesn't affect trades)
- Different complexity profiles (stateless vs stateful)
- Easier debugging and development
- Matches "single responsibility" principle from reference architecture

## Alternatives Considered

### 1. Writing to Files or Logs
Rejected because:
- Adds latency and operational overhead
- Duplicates functionality already handled by the tickerplant
- Moves the system away from event-driven design

### 2. Embedding q inside the Feed Handler
Rejected because:
- Couples C++ lifecycle and kdb runtime tightly
- Complicates deployment and debugging
- Reduces architectural clarity

### 3. Publishing Directly to an RDB
Rejected because:
- Bypasses the tickerplant's role in sequencing and fan-out
- Makes scaling and recovery more difficult
- Deviates from standard kdb design patterns

### 4. Using External Messaging Systems
Out of scope for this project:
- Introduces unnecessary infrastructure
- Distracts from core kdb architecture exploration

### 5. Synchronous IPC
Rejected because:
- Blocks the feed handler until the tickerplant acknowledges
- Increases end-to-end latency
- Not necessary given TP logging (ADR-003)

### 6. Batched Publishing
Rejected because:
- Introduces batching delay into latency measurements
- Complicates per-event latency analysis
- Not required at current message rates

May be reconsidered if throughput requirements increase.

### 7. Single Multi-Threaded Feed Handler
Rejected because:
- Adds threading complexity
- Single failure domain for both data types
- Harder to debug and reason about
- No compelling benefit at current scale

## Consequences

### Positive

- Clean, canonical ingestion pipeline
- Clear ownership boundaries between components
- Easy to reason about latency and ordering
- Trade feed handler remains simple and stateless
- Quote feed handler encapsulates book complexity
- Tick-by-tick publishing provides clear latency visibility
- Asynchronous IPC minimises feed handler blocking
- Independent processes allow independent restart
- Single TP simplifies subscriber management

### Negative / Trade-offs

- Requires a running tickerplant for ingestion
- Two processes to manage instead of one
- Quote handler maintains state (more complex than trade handler)
- Asynchronous publishing means no delivery confirmation
- Tick-by-tick has higher IPC overhead than batching
- Messages are lost if connection drops (no local buffering)

These trade-offs are acceptable and consistent with the project's goals.

## Links / References

- `../kdbx-real-time-architecture-reference.md`
- `../kdbx-real-time-architecture-measurement-notes.md`
- `adr-001-timestamps-and-latency-measurement.md` (timestamp capture in FH)
- `adr-003-tickerplant-logging-and-durability-strategy.md` (logging and durability)
- `adr-006-recovery-and-replay-strategy.md` (recovery and replay)
- `adr-009-l1-order-book-architecture.md` (quote handler design)
- `docs/specs/trades-schema.md` (trade table schema)
