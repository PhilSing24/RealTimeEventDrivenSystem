# ADR-005: Telemetry and Metrics Aggregation Strategy

## Status
Accepted (Updated 2025-12-19)

## Date
2025-12-17 (Updated 2025-12-19)

## Context

The system ingests real-time trade events from Binance via a C++ feed handler and publishes them into a kdb+/KDB-X pipeline (Tickerplant -> RDB -> RTE).

To understand system behaviour, diagnose issues, and validate latency targets, we need:
- Visibility into latency at each pipeline stage
- Throughput metrics to understand load
- Health indicators to detect problems
- Aggregated views suitable for dashboards and alerting

ADR-001 defines raw timestamp fields captured per event:
- `fhParseUs`, `fhSendUs` - feed handler segment latencies
- `fhRecvTimeUtcNs`, `tpRecvTimeUtcNs`, `rdbApplyTimeUtcNs` - wall-clock timestamps for cross-process correlation

A decision is required on **how these raw measurements are aggregated, stored, and consumed**.

## Notation

| Acronym | Definition |
|---------|------------|
| FH | Feed Handler |
| IPC | Inter-Process Communication |
| RDB | Real-Time Database |
| RTE | Real-Time Engine |
| SLO | Service-Level Objective |
| TEL | Telemetry Process |
| TP | Tickerplant |

## Decision

Telemetry will be collected as **raw per-event measurements** and **aggregated in a dedicated TEL process** that queries RDB and RTE.

### Telemetry Categories

| Category | Metrics | Source |
|----------|---------|--------|
| FH segment latencies | `fhParseUs`, `fhSendUs` | Per-event fields from FH (via RDB) |
| Pipeline latencies | `fh_to_tp_ms`, `tp_to_rdb_ms`, `e2e_system_ms` | Derived from wall-clock timestamps (via RDB) |
| Throughput | Events per second, per symbol | Computed from event counts (via RDB) |
| Analytics health | `isValid`, `fillPct`, `tradeCount5m` | Queried from RTE |

### Aggregation Location

**Raw per-event latencies are sent by the FH; aggregation happens in a dedicated TEL process.**

| Component | Responsibility |
|-----------|----------------|
| FH | Captures `fhParseUs`, `fhSendUs` per event; sends with trade data |
| TP | Passes through; adds `tpRecvTimeUtcNs` |
| RDB | Stores raw events with `rdbApplyTimeUtcNs`; serves queries |
| RTE | Computes rolling analytics; serves queries |
| TEL | Queries RDB and RTE on timer; computes aggregated telemetry |
| Dashboard | Queries TEL for telemetry, RTE for analytics |

Rationale:
- RDB remains focused on storage (single responsibility)
- RTE remains focused on rolling analytics (single responsibility)
- TEL can query multiple sources (RDB + RTE) for comprehensive metrics
- Telemetry logic can evolve without affecting storage or analytics
- Raw per-event latencies remain available in RDB for debugging

### Aggregation Strategy

**Time buckets:**

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Bucket size | 5 seconds | Stable percentiles with sufficient samples (~50-500 trades) |
| Computation frequency | Every 5 seconds (timer) | Matches bucket size |

**Percentiles (per bucket):**

| Percentile | Purpose |
|------------|---------|
| p50 | Typical latency (median) |
| p95 | Majority-case tail |
| max | Spike detection |

Note: p99 was removed because it requires ~500+ samples per bucket to meaningfully differ from p95. With 5-second buckets, p99 often equals p95. `max` provides spike detection without sample size requirements.

**Rolling windows (computed from buckets):**

| Window | Purpose | Computation |
|--------|---------|-------------|
| 1-minute | Incident detection, alerting | Last 12 buckets |
| 15-minute | Trend analysis, capacity planning | Last 180 buckets |

### Collection Architecture

```
FH --> TP --+--> RDB :5011
            |      |
            |      +-- trade_binance (raw events)
            |
            +--> RTE :5012
                   |
                   +-- rollAnalytics (rolling analytics)

TEL :5013 <-- queries RDB + RTE on 5-sec timer
    |
    +-- telemetry_latency_fh
    +-- telemetry_latency_e2e
    +-- telemetry_throughput
    +-- telemetry_analytics_health
```

The TEL process runs a 5-second timer that:
1. Queries RDB for trades in the previous bucket window
2. Computes percentiles for latency fields
3. Computes event counts per symbol
4. Queries RTE for current analytics state
5. Inserts aggregated rows into telemetry tables

### Telemetry Storage Schema

**Feed handler latency aggregates (`telemetry_latency_fh`):**

| Column | Type | Description |
|--------|------|-------------|
| `bucket` | timestamp | Start of 5-second bucket |
| `sym` | symbol | Instrument symbol |
| `parseUs_p50` | float | Median parse latency |
| `parseUs_p95` | float | 95th percentile parse latency |
| `parseUs_max` | long | Maximum parse latency |
| `sendUs_p50` | float | Median send latency |
| `sendUs_p95` | float | 95th percentile send latency |
| `sendUs_max` | long | Maximum send latency |
| `cnt` | long | Number of events in bucket |

**End-to-end latency aggregates (`telemetry_latency_e2e`):**

| Column | Type | Description |
|--------|------|-------------|
| `bucket` | timestamp | Start of 5-second bucket |
| `sym` | symbol | Instrument symbol |
| `fhToTpMs_p50` | float | Median FH to TP latency (ms) |
| `fhToTpMs_p95` | float | 95th percentile FH to TP latency |
| `fhToTpMs_max` | float | Maximum FH to TP latency |
| `tpToRdbMs_p50` | float | Median TP to RDB latency (ms) |
| `tpToRdbMs_p95` | float | 95th percentile TP to RDB latency |
| `tpToRdbMs_max` | float | Maximum TP to RDB latency |
| `e2eMs_p50` | float | Median end-to-end latency (FH to RDB) |
| `e2eMs_p95` | float | 95th percentile E2E latency |
| `e2eMs_max` | float | Maximum E2E latency |
| `cnt` | long | Number of events in bucket |

**Throughput metrics (`telemetry_throughput`):**

| Column | Type | Description |
|--------|------|-------------|
| `bucket` | timestamp | Start of 5-second bucket |
| `sym` | symbol | Instrument symbol |
| `tradeCount` | long | Number of trades |
| `totalQty` | float | Sum of trade quantities |
| `totalValue` | float | Sum of (price * qty) |

**Analytics health (`telemetry_analytics_health`):**

| Column | Type | Description |
|--------|------|-------------|
| `bucket` | timestamp | Start of 5-second bucket |
| `sym` | symbol | Instrument symbol |
| `isValid` | boolean | RTE validity flag (window >= 50% filled) |
| `fillPct` | float | RTE window fill percentage |
| `tradeCount5m` | long | Trades in RTE rolling window |
| `avgPrice5m` | float | Average price in RTE rolling window |

### Monitoring Approach

**Operational monitoring (human-facing):**

| Method | Description |
|--------|-------------|
| Dashboard queries | Poll TEL tables, display in KX Dashboards (ADR-007) |
| Visual inspection | Latency charts, throughput graphs, health indicators |
| Manual alerting | Human observes anomalies, investigates |

**Programmatic monitoring (system-reactive):**

| Method | Description |
|--------|-------------|
| RTE validity flags | `isValid`, `fillPct` in analytics (ADR-004) |
| Staleness detection | Compare `lastUpdateTime` against threshold |
| Connection state | React to `.z.pc` disconnection callbacks |

Best practice from the reference architecture:
> "Collect and publish raw metrics only. Delegate alerting, thresholds, and anomaly detection to the monitoring platform."

For this project, dashboards serve as the "monitoring platform." Formal alerting is out of scope.

### Retention Policy

**Telemetry is ephemeral**, consistent with ADR-003 system-wide stance:

| Aspect | Policy |
|--------|--------|
| Persistence | In-memory only |
| On restart | Telemetry tables start empty |
| Historical analysis | Out of scope for current phase |
| Bucket retention | Keep last 15 minutes (sufficient for rolling windows) |

Rationale:
- Consistency with ADR-003 (no durability)
- Real-time dashboards show current behaviour
- Historical telemetry analysis not required for project goals

### SLO Alignment

Telemetry aggregation supports SLO definitions from ADR-001:

| SLO Component | Telemetry Support |
|---------------|-------------------|
| Target percentiles (p50/p95/max) | Computed per bucket and queryable |
| 1-minute rolling window | Query last 12 buckets |
| 15-minute rolling window | Query last 180 buckets |
| Symbol scope | Per-symbol aggregation |
| Message type scope | Trade events only (current phase) |

Example SLO query:
```q
/ p95 E2E latency over last 1 minute, per symbol
select p95_1min: avg e2eMs_p95 by sym 
  from telemetry_latency_e2e 
  where bucket > .z.p - 00:01:00
```

## Rationale

This approach was selected because it:

- Keeps the RDB focused on storage (single responsibility)
- Keeps the RTE focused on analytics (single responsibility)
- Centralises telemetry logic in TEL where it can evolve easily
- Allows TEL to query multiple sources (RDB + RTE)
- Preserves raw per-event latencies in RDB for debugging
- Provides aggregated views suitable for dashboards
- Aligns with the ephemeral, exploratory nature of the project
- Uses 5-second buckets for stable percentiles with sufficient samples

## Alternatives Considered

### 1. Telemetry computed in RDB (original design)
Changed because:
- Mixed storage and computation responsibilities
- Could not easily capture RTE health metrics
- Violated single-responsibility principle

### 2. FH pre-aggregates into buckets
Rejected:
- Adds complexity to C++ feed handler
- Reduces flexibility (aggregation logic in compiled code)
- Loses raw per-event data for debugging

### 3. Dedicated telemetry aggregator per source
Rejected:
- Adds deployment complexity (TEL-RDB + TEL-RTE)
- Overkill for 2 sources
- Single TEL process can query both

### 4. Compute aggregates on-demand in dashboard queries
Rejected:
- Repeated computation on each query
- Poor scalability with query frequency
- Inconsistent results during computation

### 5. Persist telemetry while market data is ephemeral
Rejected:
- Inconsistent with ADR-003 stance
- Adds complexity for marginal benefit
- Historical telemetry analysis out of scope

### 6. 1-second buckets
Changed to 5-second because:
- 1-second buckets often have too few samples for stable percentiles
- p95 with 10 samples is unreliable
- 5 seconds provides ~50-500 trades per bucket

### 7. Keep p99 percentile
Rejected:
- Requires ~500+ samples to differ meaningfully from p95
- With 5-second buckets, p99 often equals p95
- `max` provides spike detection without sample size requirements

## Consequences

### Positive

- Clean separation of concerns (RDB stores, RTE computes analytics, TEL computes telemetry)
- TEL can query multiple sources for comprehensive metrics
- Flexible aggregation logic (evolves in TEL without affecting RDB/RTE)
- Raw data available in RDB for debugging
- Aggregated data available in TEL for dashboards
- Consistent ephemeral stance
- SLO metrics directly queryable
- 5-second buckets provide stable percentiles

### Negative / Trade-offs

- Additional process (TEL) to manage
- Telemetry delayed by query interval (5 seconds)
- Telemetry lost on restart
- No historical trend analysis
- 15-minute bucket retention limits lookback
- `max` is more sensitive to outliers than p99

These trade-offs are acceptable for the current phase.

## Future Evolution

| Enhancement | Trigger |
|-------------|---------|
| RTE latency metrics | Instrumentation added to RTE |
| Telemetry persistence | Historical analysis requirement |
| External monitoring platform | Production deployment, formal alerting |
| Longer retention | Capacity planning requirement |
| Additional metrics | New pipeline stages, components |

## Links / References

- `../kdbx-real-time-architecture-reference.md`
- `../kdbx-real-time-architecture-measurement-notes.md`
- `adr-001-timestamps-and-latency-measurement.md` (raw fields, SLO targets)
- `adr-003-tickerplant-logging-and-durability-strategy.md` (ephemeral stance)
- `adr-004-real-time-rolling-analytics-computation.md` (RTE validity flags)
- `adr-007-visualisation-and-consumption-strategy.md` (dashboard consumption)
