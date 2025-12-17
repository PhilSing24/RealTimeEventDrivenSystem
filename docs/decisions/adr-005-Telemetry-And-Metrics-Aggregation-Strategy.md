# ADR-004: Real-Time Rolling Analytics Computation

## Status
Accepted

## Date
2025-12-17

## Context

The system ingests real-time trade events from Binance via a C++ feed handler and publishes them into a kdb+/KDB-X pipeline (Tickerplant → RDB → Real-Time Engine).

A core objective of the project is to compute **rolling analytics** on this live data, starting with simple metrics such as:

- Average price over the last _N_ minutes
- Potentially extended later to VWAP, OHLC, counts, etc.

These analytics must:
- Update incrementally as new trades arrive
- Be query-consistent
- Reflect recent data with low latency
- Avoid full rescans of historical data on each update

Therefore, a decision is required on **where and how rolling analytics are computed**.

## Decision

Rolling analytics will be computed in a **Real-Time Engine (RTE)** process using **incremental, event-driven state updates**.

Specifically:

- The **RDB** stores the raw trade events (`trade_binance`) and provides query-consistent access.
- The **RTE** subscribes to the trade stream from the tickerplant or RDB.
- The RTE maintains **in-memory state** required to compute rolling analytics.
- Analytics are updated **per incoming event** or in small batches.
- Results are published to:
  - Dedicated analytics tables, and/or
  - Downstream consumers (dashboards, APIs, etc.).

Rolling windows are implemented using **time-based eviction** (e.g. last 5 minutes) rather than fixed-size buffers.

## Rationale

This approach aligns with established kdb+/KDB-X design patterns:

- Rolling analytics are **stateful** and naturally belong in an RTE.
- Incremental updates avoid repeated full-window scans.
- The RDB remains focused on **data storage and query consistency**, not computation.
- The RTE can be restarted independently, rebuilding state from recent data if required.
- Latency characteristics are predictable and measurable.

This separation also allows:
- Multiple analytics engines to coexist
- Different window sizes or metrics without impacting ingestion
- Independent scaling of ingestion and analytics

## Example (Conceptual)

For a rolling average price over the last 5 minutes:

- RTE maintains per-symbol state:
  - Sum of prices (or sum of price × quantity)
  - Count (or total quantity)
  - Time-ordered structure for eviction
- On each incoming trade:
  - Add new trade to state
  - Evict trades older than `now - 5 minutes`
  - Recompute derived value incrementally
- Publish updated metric

## Alternatives Considered

### Compute analytics directly in the RDB
Rejected:
- Requires repeated window scans
- Poor scalability at high update rates
- Mixes storage and computation responsibilities

### Compute analytics in the feed handler
Rejected:
- Couples business logic to ingestion
- Harder to evolve and test
- Poor fit for kdb-centric analytics workflows

### Batch analytics only
Rejected:
- Does not satisfy real-time or low-latency goals
- Not aligned with event-driven design

## Consequences

### Positive
- Clean architectural separation
- Low-latency incremental analytics
- Scalable and extensible design
- Matches industry-standard kdb patterns

### Trade-offs
- RTE state must be rebuilt after restart
- Requires explicit window management logic
- Slightly more complex than ad-hoc queries

## Links / References
- `docs/kdbx-real-time-architecture-reference.md`
- `docs/kdbx-real-time-architecture-measurement-notes.md`
- `docs/specs/trades-schema.md`
- Data Intellect: *Building Real Time Event Driven KDB-X Systems*
