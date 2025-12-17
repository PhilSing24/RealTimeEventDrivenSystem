# ADR-006: Recovery and Replay Strategy

## Status
Accepted

## Date
2025-12-17

## Context

In a typical production-grade KDB-X architecture, recovery and replay are achieved via:
- Durable tickerplant logs
- Replay of persisted data on restart
- Deterministic rebuild of downstream state (RDB, RTE)

However, this project is explicitly **exploratory and incremental** in nature. The current system ingests real-time Binance trade data and focuses on:
- Architecture understanding
- Latency measurement discipline
- Real-time analytics behaviour

At this stage, **no durable logging layer** has been introduced.

## Decision

At the current stage of the project:

- **No recovery or replay mechanism is implemented**
- The system operates as a **pure real-time, transient pipeline**
- On restart or failure, the system resumes from the live stream only

Specifically:
- No tickerplant log files are written
- No replay into RDB or analytics is supported
- No attempt is made to reconstruct historical state after restart

## Rationale

This decision is intentional and aligned with the project goals:

- Keeps the system simple and focused
- Avoids premature optimisation and complexity
- Allows clear reasoning about live latency and flow behaviour
- Matches the transient nature of exchange WebSocket feeds

Recovery and replay concerns are deferred until:
- The analytics require historical continuity
- State reconstruction becomes operationally necessary
- Log-based durability is explicitly introduced

## Consequences

### Positive
- Simplified system architecture
- Faster iteration and experimentation
- No ambiguity between live vs replayed data
- Clear focus on real-time behaviour

### Negative / Limitations
- Loss of analytics state on restart
- No historical backfill or gap recovery
- Not suitable for production trading or regulatory use

These limitations are acceptable for the current phase.

## Future Considerations

If durability is required in later phases, the following may be introduced:
- Tickerplant logging
- Controlled replay into RDB
- Explicit recovery modes (live vs replay)
- Telemetry-aware replay throttling

Such changes will be captured in a future ADR.

## Links / References
- `docs/kdbx-real-time-architecture-reference.md`
- `docs/kdbx-real-time-architecture-measurement-notes.md`
