# ADR-003: Tickerplant Logging and Durability Strategy

## Status
Accepted

## Date
2025-12-17

## Context

In a canonical kdb real-time architecture, the tickerplant (TP) is responsible for:

- Sequencing inbound events
- Publishing updates to real-time databases (RDBs)
- Optionally providing a durability boundary via logging

This project ingests real-time Binance trade data through an external C++ feed handler and publishes it directly into a tickerplant via IPC (ADR-002).

A key design decision is whether the tickerplant should:
- Log incoming updates to disk (durable TP), or
- Operate purely in-memory (non-durable TP)

This decision affects recovery semantics, operational complexity, latency, and alignment with the project's exploratory goals.

## Notation

| Acronym | Definition |
|---------|------------|
| FH | Feed Handler |
| HDB | Historical Database |
| IPC | Inter-Process Communication |
| RDB | Real-Time Database |
| RTE | Real-Time Engine |
| TP | Tickerplant |

## Decision

The tickerplant will initially operate **without persistent logging**.

### Architecture Variant

This follows the **Non-Logging Tickerplant** pattern described in the reference architecture:

> "An alternative architecture is to decouple data distribution from data persistence by splitting the responsibilities of the tickerplant. In this variant: The tickerplant is responsible only for distributing data."

In this project:
- The tickerplant is responsible only for distributing data
- No separate logging process is implemented
- Data persistence is not provided at any layer

### Logging Configuration

- The tickerplant will not write update logs to disk.
- Data durability is not guaranteed across process restarts.
- Recovery relies on upstream replay (Binance reconnect / resubscribe).
- Logging may be introduced later without changing the feed handler contract.

### End-of-Day Behaviour

- No Historical Database (HDB) is implemented
- All data is ephemeral and lost on process restart or end of day
- No end-of-day rollover or persistence occurs
- This aligns with the project's focus on real-time behaviour, not historical analysis

### Downstream Recovery Implications

Without tickerplant logging, downstream components cannot recover historical state:

| Component | On Restart | Consequence |
|-----------|------------|-------------|
| TP | Restarts empty | RDB/RTE must resubscribe; data gap from restart point |
| RDB | Starts empty | Only receives data from restart time onwards |
| RTE | State lost | Rolling analytics invalid until window refills (see ADR-004) |

This is acceptable because:
- The project is exploratory and does not require session continuity
- Binance data has no regulatory retention requirements in this context
- Analytics validity is observable via dashboards (ADR-007)

### Telemetry Data Persistence

Telemetry data (e.g., `telemetry_latency_fh` defined in ADR-001) is also ephemeral:
- Stored in-memory only
- Lost on process restart
- Sufficient for real-time observation and debugging
- Historical telemetry analysis is out of scope

### System-Wide Durability Stance

Combined with ADR-002 (async IPC, no local buffering), the entire pipeline is ephemeral:

| Failure Scenario | Data Recovery |
|------------------|---------------|
| FH loses connection to TP | Messages dropped; not recoverable |
| TP loses connection to RDB | Messages dropped; not recoverable |
| Any component restarts | State lost; resumes from live stream only |

This is an explicit, system-wide design choice for the current phase.

## Rationale

This option was selected because it:

- Keeps the initial system simple and focused.
- Minimises operational overhead during early development.
- Avoids premature optimisation for durability in an exploratory project.
- Aligns with the fact that Binance market data can be re-subscribed after reconnect.
- Preserves low latency by avoiding synchronous disk I/O in the critical path.

### Latency Benefit

Disabling logging provides measurable latency advantages:
- No synchronous disk I/O in the tickerplant critical path
- Lower and more predictable publish latency to downstream subscribers
- Cleaner latency measurements without I/O variance
- Aligns with the "hot path" optimisation pattern from the reference architecture

## Alternatives Considered

### 1. Durable Tickerplant (Logging Enabled)
Rejected initially because:
- Introduces additional complexity (log rotation, replay tooling).
- Adds I/O overhead that complicates latency analysis.
- Is not required for validating architecture patterns or latency measurement.

This option remains viable for a later phase.

### 2. Logging in the Feed Handler
Rejected because:
- Duplicates tickerplant responsibilities.
- Complicates recovery semantics.
- Violates separation of concerns.

### 3. Separate Logger Process
Rejected because:
- Adds architectural complexity without benefit at this stage.
- Introduces coordination challenges between logger and TP.
- Overkill for exploratory project.

### 4. External Persistence Layer
Out of scope for this project:
- Adds infrastructure complexity.
- Distracts from core kdb architecture exploration.

### 5. Historical Database (HDB)
Rejected because:
- Requires logging to populate.
- Historical analysis is out of scope for current phase.
- Adds operational complexity (EOD rollover, partitioning, etc.).

## Consequences

### Positive

- Simple and fast ingestion path.
- Clear architectural responsibilities.
- Easier reasoning about latency measurements.
- Faster iteration during development.
- Lower latency due to no disk I/O in critical path.
- No operational burden of log management.

### Negative / Trade-offs

- Data is lost if any component restarts.
- No historical replay from kdb logs.
- Downstream consumers must tolerate gaps after restarts.
- RTE rolling analytics are invalid after restart until window refills.
- No historical analysis capability.
- No audit trail or regulatory compliance.

These trade-offs are acceptable given the project's exploratory and educational nature.

## Future Evolution

If durability becomes a requirement, the following changes may be introduced:

| Change | Impact |
|--------|--------|
| Enable tickerplant logging | Requires log directory, rotation policy |
| Add replay tooling | Repopulate RDB/RTE on restart |
| Introduce HDB | End-of-day rollover, partitioned storage |
| Sequence-number gap detection | Validate replay completeness |

Such changes would not require modification of:
- The feed handler
- The trade schema
- ADR-001 (timestamps) or ADR-002 (ingestion path)

A new ADR will be created if durability requirements change.

## Links / References

- `../kdbx-real-time-architecture-reference.md`
- `../kdbx-real-time-architecture-measurement-notes.md`
- `adr-001-timestamps-and-latency-measurement.md` (telemetry schema)
- `adr-002-feed-handler-to-kdb-ingestion-path.md` (async IPC, no buffering)
- `adr-004-real-time-rolling-analytics-computation.md` (RTE state implications)
- `adr-006-recovery-and-replay-strategy.md` (recovery deferral)
- `adr-007-visualisation-and-consumption-strategy.md` (observability)