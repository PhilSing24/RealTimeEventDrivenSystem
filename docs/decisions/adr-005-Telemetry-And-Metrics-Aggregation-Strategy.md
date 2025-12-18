# ADR-005: Telemetry and Metrics Aggregation Strategy

## Status
Accepted

## Date
2025-12-17

## Context

The system ingests real-time trade events from Binance via a C++ feed handler and publishes them into a kdb+/KDB-X pipeline (Tickerplant → RDB → RTE).

To understand system behaviour, diagnose issues, and validate latency targets, we need:
- Visibility into latency at each pipeline stage
- Throughput metrics to understand load
- Health indicators to detect problems
- Aggregated views suitable for dashboards and alerting

ADR-001 defines raw timestamp fields captured per event:
- `fhParseUs`, `fhSendUs` — feed handler segment latencies
- `fhRecvTimeUtcNs`, `tpRecvTimeUtc`, `rdbApplyTimeUtc` — wall-clock timestamps for cross-process correlation

A decision is required on **how these raw measurements are aggregated, stored, and consumed**.

## Notation

| Acronym | Definition |
|---------|------------|
| FH | Feed Handler |
| IPC | Inter-Process Communication |
| RDB | Real-Time Database |
| RTE | Real-Time Engine |
| SLO | Service-Level Objective |
| TP | Tickerplant |

## Decision

Telemetry will be collected as **raw per-event measurements** and **aggregated within kdb** (specifically in the RDB) for dashboard consumption.

### Telemetry Categories

| Category | Metrics | Source |
|----------|---------|--------|
| FH segment latencies | `fhParseUs`, `fhSendUs` | Per-event fields from FH |
| Pipeline latencies | `fh_to_tp_ms`, `tp_to_rdb_ms`, `e2e_system_ms` | Derived from wall-clock timestamps |
| Throughput | Events per second, per symbol | Computed from event counts |
| Health | Connection state, last update time, staleness flags | Process-level indicators |

### Aggregation Location

**Raw per-event latencies are sent by the FH; aggregation happens in kdb.**

| Component | Responsibility |
|-----------|----------------|
| FH | Captures `fhParseUs`, `fhSendUs` per event; sends with trade data |
| TP | Passes through; optionally adds `tpRecvTimeUtc` |
| RDB | Stores raw events; computes aggregated telemetry on timer |
| Dashboard | Queries aggregated telemetry tables |

Rationale:
- FH remains simple (no aggregation logic in C++)
- Aggregation logic can evolve without FH changes
- Raw per-event latencies available for debugging
- IPC overhead acceptable at current scale (2 symbols)

### Aggregation Strategy

**Time buckets:**

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Bucket size | 1 second | Granular enough for incident detection |
| Computation frequency | Every 1 second (timer) | Matches bucket size |

**Percentiles (per bucket):**

| Percentile | Purpose |
|------------|---------|
| p50 | Typical latency (median) |
| p95 | Majority-case tail |
| p99 | Operationally significant tail |
| max | Spike detection |

**Rolling windows (computed from buckets):**

| Window | Purpose | Computation |
|--------|---------|-------------|
| 1-minute | Incident detection, alerting | Last 60 buckets |
| 15-minute | Trend analysis, capacity planning | Last 900 buckets |

### Collection Architecture
```
FH ──► TP ──► RDB
              │
              ├── trade_binance (raw events with latency fields)
              │
              └── [1-sec timer]
                    │
                    ├── telemetry_latency_fh (FH segment latencies)
                    ├── telemetry_latency_e2e (pipeline latencies)
                    └── telemetry_throughput (event counts)
```

The RDB runs a 1-second timer that:
1. Scans recent trades (last 1 second)
2. Computes percentiles for latency fields
3. Computes event counts per symbol
4. Inserts aggregated rows into telemetry tables

### Telemetry Storage Schema

**Feed handler latency aggregates (`telemetry_latency_fh`):**

| Column | Type | Description |
|--------|------|-------------|
| `bucket` | timestamp | Start of 1-second bucket |
| `sym` | symbol | Instrument symbol |
| `parseUs_p50` | float | Median parse latency |
| `parseUs_p95` | float | 95th percentile parse latency |
| `parseUs_p99` | float | 99th percentile parse latency |
| `parseUs_max` | float | Maximum parse latency |
| `sendUs_p50` | float | Median send latency |
| `sendUs_p95` | float | 95th percentile send latency |
| `sendUs_p99` | float | 99th percentile send latency |
| `sendUs_max` | float | Maximum send latency |
| `count` | long | Number of events in bucket |

**End-to-end latency aggregates (`telemetry_latency_e2e`):**

| Column | Type | Description |
|--------|------|-------------|
| `bucket` | timestamp | Start of 1-second bucket |
| `sym` | symbol | Instrument symbol |
| `fhToTpMs_p50` | float | Median FH to TP latency |
| `fhToTpMs_p95` | float | 95th percentile FH to TP latency |
| `fhToTpMs_p99` | float | 99th percentile FH to TP latency |
| `tpToRdbMs_p50` | float | Median TP to RDB latency |
| `tpToRdbMs_p95` | float | 95th percentile TP to RDB latency |
| `tpToRdbMs_p99` | float | 99th percentile TP to RDB latency |
| `e2eMs_p50` | float | Median end-to-end latency |
| `e2eMs_p95` | float | 95th percentile end-to-end latency |
| `e2eMs_p99` | float | 99th percentile end-to-end latency |
| `count` | long | Number of events in bucket |

**Throughput metrics (`telemetry_throughput`):**

| Column | Type | Description |
|--------|------|-------------|
| `bucket` | timestamp | Start of 1-second bucket |
| `sym` | symbol | Instrument symbol |
| `tradeCount` | long | Number of trades |
| `totalQty` | float | Total traded quantity |
| `totalValue` | float | Total traded value (price × qty) |

**Health indicators (`telemetry_health`):**

| Column | Type | Description |
|--------|------|-------------|
| `ts` | timestamp | Observation time |
| `component` | symbol | Component name (FH, TP, RDB, RTE) |
| `status` | symbol | Status (`ok`, `stale`, `disconnected`) |
| `lastUpdateTime` | timestamp | Time of last received update |
| `connectionState` | symbol | IPC connection state |

### Monitoring Approach

**Operational monitoring (human-facing):**

| Method | Description |
|--------|-------------|
| Dashboard queries | Poll telemetry tables, display in KX Dashboards (ADR-007) |
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
| Target percentiles (p50/p95/p99) | Computed per bucket and queryable |
| 1-minute rolling window | Query last 60 buckets |
| 15-minute rolling window | Query last 900 buckets |
| Symbol scope | Per-symbol aggregation |
| Message type scope | Trade events only (current phase) |

Example SLO query:
```q
/ p99 FH parse latency over last 1 minute, per symbol
select p99_1min: avg parseUs_p99 by sym 
  from telemetry_latency_fh 
  where bucket > .z.p - 00:01:00
```

## Rationale

This approach was selected because it:

- Keeps the feed handler simple (no aggregation logic in C++)
- Centralises telemetry logic in kdb where it can evolve easily
- Preserves raw per-event latencies for debugging
- Provides aggregated views suitable for dashboards
- Aligns with the ephemeral, exploratory nature of the project
- Avoids premature complexity (no separate telemetry process)

## Alternatives Considered

### 1. FH pre-aggregates into buckets
Rejected:
- Adds complexity to C++ feed handler
- Reduces flexibility (aggregation logic in compiled code)
- Loses raw per-event data for debugging

### 2. Dedicated telemetry aggregator process
Rejected:
- Adds deployment complexity
- Overkill for 2 symbols and exploratory project
- RDB already has the data

May be reconsidered if:
- Symbol universe grows significantly
- RDB query load becomes a concern
- Multiple consumers need different aggregation views

### 3. Compute aggregates on-demand in dashboard queries
Rejected:
- Repeated computation on each query
- Poor scalability with query frequency
- Inconsistent results during computation

### 4. Persist telemetry while market data is ephemeral
Rejected:
- Inconsistent with ADR-003 stance
- Adds complexity for marginal benefit
- Historical telemetry analysis out of scope

### 5. No aggregation (raw only)
Rejected:
- Dashboard queries would be slow
- Repeated percentile computation expensive
- Poor user experience

## Consequences

### Positive

- Simple feed handler (raw metrics only)
- Flexible aggregation logic (evolves in kdb)
- Raw data available for debugging
- Aggregated data available for dashboards
- Consistent ephemeral stance
- SLO metrics directly queryable
- Single source of truth (RDB)

### Negative / Trade-offs

- RDB has dual responsibility (storage + telemetry aggregation)
- 1-second timer adds minor load to RDB
- Telemetry lost on restart
- No historical trend analysis
- 15-minute bucket retention limits lookback

These trade-offs are acceptable for the current phase.

## Future Evolution

| Enhancement | Trigger |
|-------------|---------|
| Dedicated telemetry process | RDB load concerns, multiple consumers |
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