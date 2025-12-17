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

This decision affects recovery semantics, operational complexity, latency, and alignment with the project’s exploratory goals.

## Decision

The tickerplant will initially operate **without persistent logging**.

Specifically:

- The tickerplant will not write update logs to disk.
- Data durability is not guaranteed across process restarts.
- Recovery relies on upstream replay (Binance reconnect / resubscribe).
- Logging may be introduced later without changing the feed handler contract.

## Rationale

This option was selected because it:

- Keeps the initial system simple and focused.
- Minimises operational overhead during early development.
- Avoids premature optimisation for durability in an exploratory project.
- Aligns with the fact that Binance market data can be re-subscribed after reconnect.
- Preserves low latency by avoiding synchronous disk I/O in the critical path.

For this project, correctness and architectural clarity are prioritised over full fault tolerance.

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

### 3. External Persistence Layer
Out of scope for this project:
- Adds infrastructure complexity.
- Distracts from core kdb architecture exploration.

## Consequences

### Positive

- Simple and fast ingestion path.
- Clear architectural responsibilities.
- Easier reasoning about latency measurements.
- Faster iteration during development.

### Trade-offs

- Data is lost if the tickerplant or RDB restarts.
- No historical replay from kdb logs.
- Downstream consumers must tolerate gaps after restarts.

These trade-offs are acceptable given the project’s exploratory and educational nature.

## Future Evolution

If durability becomes a requirement, the following changes may be introduced:

- Enable tickerplant logging to disk.
- Add replay tooling to repopulate RDBs on restart.
- Introduce sequence-number-based gap detection.

Such changes would not require modification of:
- The feed handler
- The trade schema
- Existing ADRs

## Links / References

- `docs/decisions/adr-002-feed-handler-to-kdb-ingestion-path.md`
- `docs/decisions/adr-001-timestamps-and-latency-measurement.md`
- `docs/kdbx-real-time-architecture-reference.md`
