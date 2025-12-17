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

## Decision

The feed handler will publish data **directly into a Tickerplant via IPC**.

Specifically:

- The C++ feed handler connects to a running kdb tickerplant using the kdb+ C API.
- Each normalised trade event is published as an update message to the tickerplant.
- The tickerplant remains the single ingress point for:
  - Logging (if enabled)
  - Fan-out to RDB(s)
  - Time-ordering and sequencing
- The feed handler remains stateless with respect to downstream consumers.

## Rationale

This option was selected because it:

- Aligns with canonical kdb real-time architectures.
- Preserves a clear separation of concerns:
  - Feed handler: external I/O, parsing, normalisation, timestamp capture
  - Tickerplant: sequencing, publication, durability boundary
  - RDB: query consistency and real-time analytics
- Minimises end-to-end latency by avoiding intermediate persistence layers.
- Keeps operational complexity low for an exploratory but realistic system.
- Allows later evolution (e.g. replication, logging, recovery) without changing the feed handler contract.

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
- Bypasses the tickerplant’s role in sequencing and fan-out.
- Makes scaling and recovery more difficult.
- Deviates from standard kdb design patterns.

### 4. Using External Messaging Systems
Out of scope for this project:
- Introduces unnecessary infrastructure.
- Distracts from core kdb architecture exploration.

## Consequences

### Positive

- Clean, canonical ingestion pipeline.
- Clear ownership boundaries between components.
- Easy to reason about latency and ordering.
- Feed handler remains simple and testable.

### Trade-offs

- Requires a running tickerplant for ingestion.
- Recovery and replay are delegated to upstream sources or TP design.
- Feed handler cannot independently guarantee durability.

These trade-offs are acceptable and consistent with the project’s goals.

## Links / References

- `docs/kdbx-real-time-architecture-reference.md`
- `docs/kdbx-real-time-architecture-measurement-notes.md`
- `docs/specs/trades-schema.md`
- `docs/decisions/adr-001-timestamps-and-latency-measurement.md`
