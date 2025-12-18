# ADR-004: Real-Time Rolling Analytics Computation

## Status
Accepted

## Date
2025-12-17

## Context

The system ingests real-time trade events from Binance via a C++ feed handler and publishes them into a kdb+/KDB-X pipeline (Tickerplant → RDB → Real-Time Engine).

A core objective of the project is to compute **rolling analytics** on this live data, starting with simple metrics such as:

- Average price over the last N minutes
- Trade count over the last N minutes
- Potentially extended later to VWAP, OHLC, etc.

These analytics must:
- Update incrementally as new trades arrive
- Be query-consistent
- Reflect recent data with low latency
- Avoid full rescans of historical data on each update

A decision is required on **where and how rolling analytics are computed**.

## Notation

| Acronym | Definition |
|---------|------------|
| IPC | Inter-Process Communication |
| OHLC | Open, High, Low, Close |
| RDB | Real-Time Database |
| RTE | Real-Time Engine |
| TP | Tickerplant |
| VWAP | Volume-Weighted Average Price |

## Decision

Rolling analytics will be computed in a **Real-Time Engine (RTE)** process using **incremental, event-driven state updates**.

### Architectural Placement

- The **RDB** stores raw trade events (`trade_binance`) and provides query-consistent access.
- The **RTE** computes and maintains rolling analytics as a dedicated process.
- The RTE is a peer to the RDB, not downstream of it during normal operation.

### Subscription Model

- The RTE subscribes **directly to the tickerplant** for live trade updates.
- The RTE is a peer subscriber alongside the RDB.
- The RTE does not query the RDB during normal operation (only for recovery).
```
TP ──┬──► RDB (storage)
     │
     └──► RTE (analytics)
```

### Processing Mode

The RTE processes updates **tick-by-tick**:
- Each incoming trade immediately updates rolling state
- Analytics are recomputed on each update
- No internal batching or buffering

Rationale:
- Matches FH→TP tick-by-tick model (ADR-002)
- Provides lowest latency for analytics updates
- Simplifies latency measurement
- Consistent reasoning across the entire pipeline
- Sustainable at current message rates (2 symbols)

### Initial Analytics Scope

| Analytic | Definition | Window | Granularity |
|----------|------------|--------|-------------|
| `avgPrice` | Simple mean of trade prices | 5 minutes | Per symbol |
| `tradeCount` | Count of trades | 5 minutes | Per symbol |

Additional analytics (VWAP, OHLC) may be added in future phases.

### Window Configuration

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Window size | 5 minutes | Long enough for meaningful smoothing, short enough for responsiveness |
| Eviction granularity | Per event | Lazy eviction on each update |

Window size may be made configurable in future iterations.

### State Schema

**Rolling window buffer (trades within window):**

| Column | Type | Description |
|--------|------|-------------|
| `sym` | symbol (key, `u#`) | Instrument symbol |
| `times` | timestamp list | Trade timestamps in window |
| `prices` | float list | Trade prices in window |
| `qtys` | float list | Trade quantities in window |

**Derived analytics (current values):**

| Column | Type | Description |
|--------|------|-------------|
| `sym` | symbol (key, `u#`) | Instrument symbol |
| `avgPrice` | float | Rolling average price |
| `tradeCount` | long | Number of trades in window |
| `windowStart` | timestamp | Oldest trade time in window |
| `isValid` | boolean | True if window is sufficiently filled |
| `fillPct` | float | Percentage of window duration with data |
| `updateTime` | timestamp | Time analytics were last updated |

### Data Structure Decisions

Following the reference architecture performance guidance:

| Decision | Rationale |
|----------|-----------|
| Keyed tables with `u` attribute on symbol | O(1) lookup regardless of symbol count |
| Flat columns for analytics output | Better memory efficiency and query performance |
| Lists per symbol for window buffer | Acceptable given small symbol universe (2 symbols) |

The `u` attribute ensures:
> "Applying a `u` attribute to the symbol key removes the dependency on key cardinality by enforcing uniqueness."

### Window Eviction Strategy

**Lazy eviction on update:**

1. On each incoming trade:
   - Evict entries older than `now - windowSize`
   - Add new trade to window buffer
   - Recompute derived analytics

Rationale:
- Simple implementation
- Acceptable for moderate update rates
- No timer complexity

Trade-off: Stale entries may accumulate if a symbol has no updates. This is acceptable because:
- Dashboard polling (ADR-007) provides regular visibility
- Symbol universe is small and active

Future enhancement: Add periodic timer cleanup if memory pressure is observed.

### Publishing Mechanism

**Query-only (pull) for initial phase:**

- Dashboards query RTE state via synchronous IPC
- No downstream push publication
- Aligns with ADR-007 polling-based visualisation

Interface:
- Query `rollAnalytics` table for current derived values
- Query `rollWindow` table for raw window data (diagnostics)

Future enhancement: Add push publication if streaming consumers are introduced.

### Validity Indicator

The RTE exposes data quality metrics to support dashboard display:

| Field | Description |
|-------|-------------|
| `isValid` | True if window contains sufficient data (e.g., >50% fill) |
| `fillPct` | Percentage of window duration covered by data |
| `windowStart` | Timestamp of oldest trade in window |
| `updateTime` | Timestamp of most recent analytics update |

Consumers (ADR-007 dashboards) should display validity status alongside analytics values.

### Recovery Strategy

On RTE restart:

| Step | Action |
|------|--------|
| 1 | Connect and subscribe to tickerplant for live updates |
| 2 | Query RDB for trades within the rolling window period |
| 3 | Replay RDB data into rolling state |
| 4 | Mark `isValid = false` until window is sufficiently filled |
| 5 | Continue processing live updates |

Limitation: If RDB is also empty (e.g., full system restart), RTE starts with empty state and analytics are invalid until window fills naturally.

This aligns with ADR-003 (no TP logging) and ADR-006 (no replay mechanism).

### Performance Characteristics

| Metric | Target | Notes |
|--------|--------|-------|
| Memory | O(symbols × trades per window) | ~2 symbols × 5 min of trades |
| CPU per update | O(evicted trades) amortised | Typically O(1) |
| Update latency | < 1ms p99 | Analytics recomputation |

Expected memory footprint: Minimal given 2 symbols and 5-minute window.

## Rationale

This approach aligns with established kdb+/KDB-X design patterns:

- Rolling analytics are **stateful** and naturally belong in an RTE.
- Incremental updates avoid repeated full-window scans.
- The RDB remains focused on **data storage and query consistency**, not computation.
- The RTE can be restarted independently, rebuilding state from RDB if available.
- Latency characteristics are predictable and measurable.

This separation also allows:
- Multiple analytics engines to coexist
- Different window sizes or metrics without impacting ingestion
- Independent scaling of ingestion and analytics

## Alternatives Considered

### 1. Compute analytics directly in the RDB
Rejected:
- Requires repeated window scans on each query
- Poor scalability at high update rates
- Mixes storage and computation responsibilities

### 2. Compute analytics in the feed handler
Rejected:
- Couples business logic to ingestion
- Harder to evolve and test
- Poor fit for kdb-centric analytics workflows

### 3. Batch analytics only
Rejected:
- Does not satisfy real-time or low-latency goals
- Not aligned with event-driven design

### 4. Micro-batch processing at RTE
Rejected for current phase:
- Adds batching delay into latency measurements
- Inconsistent with tick-by-tick model elsewhere (ADR-002)
- Not required at current message rates

May be reconsidered if throughput requirements increase significantly.

### 5. RTE subscribes to RDB instead of TP
Rejected:
- Adds unnecessary hop in data path
- Increases latency
- RDB is for storage/query, not event distribution

## Consequences

### Positive

- Clean architectural separation
- Low-latency incremental analytics
- Scalable and extensible design
- Matches industry-standard kdb patterns
- Tick-by-tick consistency across the pipeline
- Clear validity indicators for consumers
- Recovery possible from RDB

### Negative / Trade-offs

- RTE state must be rebuilt after restart
- Requires explicit window management logic
- Slightly more complex than ad-hoc queries
- Lists per symbol may need restructuring if symbol count grows significantly
- No analytics during window fill period after restart

These trade-offs are acceptable for the current phase.

## Future Evolution

| Enhancement | Trigger |
|-------------|---------|
| Add VWAP, OHLC analytics | Business requirement |
| Configurable window sizes | Multiple consumer needs |
| Micro-batch processing | High message rates, CPU pressure |
| Push publication | Streaming consumer requirement |
| Timer-based eviction | Memory pressure observed |
| Multiple RTE instances | Horizontal scaling needed |

## Links / References

- `../kdbx-real-time-architecture-reference.md`
- `../kdbx-real-time-architecture-measurement-notes.md`
- `adr-001-timestamps-and-latency-measurement.md` (latency targets)
- `adr-002-feed-handler-to-kdb-ingestion-path.md` (tick-by-tick precedent)
- `adr-003-tickerplant-logging-and-durability-strategy.md` (no TP logging)
- `adr-006-recovery-and-replay-strategy.md` (recovery deferral)
- `adr-007-visualisation-and-consumption-strategy.md` (dashboard consumption)