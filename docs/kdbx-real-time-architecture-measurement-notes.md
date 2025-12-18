# Latency Measurement Notes

## Purpose

This document provides practical guidance on how latency measurement is defined and implemented for this project.

It serves as:
- A companion to the ADRs (particularly ADR-001)
- A reference for implementation of timestamp capture and latency calculation
- Documentation of the trust model for cross-process measurements

This document is **project-specific** and reflects decisions made in the ADRs.

## Notation

| Acronym | Definition |
|---------|------------|
| E2E | End-to-End |
| FH | Feed Handler |
| IPC | Inter-Process Communication |
| NTP | Network Time Protocol |
| PTP | Precision Time Protocol (IEEE 1588) |
| RDB | Real-Time Database |
| RTE | Real-Time Engine |
| SLO | Service-Level Objective |
| TP | Tickerplant |
| UTC | Coordinated Universal Time |

## Measurement Points

### Overview

The following measurement points are captured across the pipeline:
```
Binance ──► FH ──► TP ──► RDB
                    │
                    └──► RTE
```

### Upstream (Binance)

| Point | Field Name | Source | Unit | Description |
|-------|------------|--------|------|-------------|
| Exchange event time | `exchEventTimeMs` | Binance `E` field | ms since epoch | Time Binance generated the event |
| Exchange trade time | `exchTradeTimeMs` | Binance `T` field | ms since epoch | Time the trade occurred |

Notes:
- For trade events, `E` and `T` may be equal
- Both are server-side timestamps from Binance
- Clock skew between Binance and local system is expected

### Feed Handler

| Point | Field Name | Clock Type | Unit | Description |
|-------|------------|------------|------|-------------|
| FH receive time | `fhRecvTimeUtcNs` | Wall-clock | ns since epoch | When WebSocket message is available to process |
| FH parse duration | `fhParseUs` | Monotonic | microseconds | Duration from receive to parse/normalise complete |
| FH send duration | `fhSendUs` | Monotonic | microseconds | Duration from parse complete to IPC send initiation |
| FH sequence number | `fhSeqNo` | N/A | integer | Monotonically increasing per FH instance |

Notes:
- `fhRecvTimeUtcNs` is wall-clock for cross-process correlation
- `fhParseUs` and `fhSendUs` are monotonic-derived durations (always trusted)
- `fhSeqNo` supports gap detection (see ADR-001, ADR-006)

### Tickerplant

| Point | Field Name | Clock Type | Unit | Description |
|-------|------------|------------|------|-------------|
| TP receive time | `tpRecvTimeUtc` | Wall-clock | kdb timestamp | When TP receives message (`.z.p`) |

Notes:
- Captured in `.z.ps` handler
- Used for FH-to-TP latency calculation

**Not implemented (ADR-003):**

| Point | Description | Status |
|-------|-------------|--------|
| TP log time | Time log append complete | Not applicable; no TP logging |

### Real-Time Database

| Point | Field Name | Clock Type | Unit | Description |
|-------|------------|------------|------|-------------|
| RDB apply time | `rdbApplyTimeUtc` | Wall-clock | kdb timestamp | When update becomes query-consistent |

Notes:
- Captured after `upd` function completes
- Represents end of core pipeline (data queryable)

### Real-Time Engine

| Point | Field Name | Clock Type | Unit | Description |
|-------|------------|------------|------|-------------|
| RTE receive time | `rteRecvTimeUtc` | Wall-clock | kdb timestamp | When RTE receives update from TP |
| RTE compute time | `rteComputeUs` | Monotonic | microseconds | Duration of analytics computation |
| RTE publish time | `rtePublishTimeUtc` | Wall-clock | kdb timestamp | When analytics become query-consistent |

Notes:
- RTE subscribes directly to TP (peer to RDB)
- `rteComputeUs` measures rolling analytics update time
- `rtePublishTimeUtc` represents end of analytics pipeline

## Field Mapping Summary

| Measurement Point | ADR-001 Field | Stored In | Notes |
|-------------------|---------------|-----------|-------|
| Exchange event time | `exchEventTimeMs` | `trade_binance` | From Binance |
| Exchange trade time | `exchTradeTimeMs` | `trade_binance` | From Binance |
| FH receive | `fhRecvTimeUtcNs` | `trade_binance` | Nanoseconds |
| FH parse duration | `fhParseUs` | `trade_binance` | Microseconds |
| FH send duration | `fhSendUs` | `trade_binance` | Microseconds |
| FH sequence | `fhSeqNo` | `trade_binance` | Integer |
| TP receive | `tpRecvTimeUtc` | `trade_binance` | kdb timestamp |
| RDB apply | `rdbApplyTimeUtc` | `trade_binance` | kdb timestamp |
| RTE receive | `rteRecvTimeUtc` | Internal | Optional |
| RTE compute | `rteComputeUs` | Telemetry | Optional |
| RTE publish | `rtePublishTimeUtc` | Internal | Optional |

## Segment Latency Definitions

### Feed Handler Segments (Monotonic — Always Trusted)

| Segment | Definition | Formula |
|---------|------------|---------|
| `fh_parse_us` | Parse/normalise duration | `fhParseUs` (captured directly) |
| `fh_send_us` | Post-parse to IPC initiation | `fhSendUs` (captured directly) |
| `fh_total_us` | Total FH processing | `fhParseUs + fhSendUs` |

These are derived from monotonic clock and are **always trusted** regardless of clock sync.

### Cross-Process Segments (Wall-Clock — Trust Depends on Sync)

| Segment | Definition | Formula | Notes |
|---------|------------|---------|-------|
| `market_to_fh_ms` | Binance to FH receive | `(fhRecvTimeUtcNs / 1e6) - exchEventTimeMs` | Indicative; includes network + exchange semantics |
| `fh_to_tp_ms` | FH send to TP receive | `tpRecvTimeUtc - fhRecvTimeUtc` | Requires unit conversion |
| `tp_to_rdb_ms` | TP receive to RDB apply | `rdbApplyTimeUtc - tpRecvTimeUtc` | |
| `tp_to_rte_ms` | TP receive to RTE receive | `rteRecvTimeUtc - tpRecvTimeUtc` | Optional |
| `rte_compute_us` | RTE analytics computation | `rteComputeUs` (captured directly) | Monotonic |
| `e2e_to_rdb_ms` | FH receive to RDB apply | `rdbApplyTimeUtc - fhRecvTimeUtc` | Full ingestion pipeline |
| `e2e_to_rte_ms` | FH receive to RTE publish | `rtePublishTimeUtc - fhRecvTimeUtc` | Full analytics pipeline |

### Unit Conversions

| From | To | Conversion |
|------|-----|------------|
| Nanoseconds | Milliseconds | Divide by 1,000,000 |
| Microseconds | Milliseconds | Divide by 1,000 |
| kdb timestamp | Milliseconds since epoch | Standard kdb conversion |

## Clock Types

### Monotonic Time (Duration Clock)

**Purpose:** Measure durations within a single process.

**Characteristics:**
- Never moves backwards
- Not affected by NTP/PTP adjustments
- Cannot be compared across processes
- Suitable for segment timing within FH or RTE

**Implementation:**
- C++: `std::chrono::steady_clock`
- kdb: Use timestamp differences within same process

**Trust:** Always trusted for duration measurements.

### Wall-Clock Time (UTC/Calendar)

**Purpose:** Correlate events across processes/hosts.

**Characteristics:**
- Can be adjusted by NTP/PTP
- Can move backwards (rare, but possible)
- Comparable across processes when clock sync is acceptable
- Subject to clock skew between hosts

**Implementation:**
- C++: `std::chrono::system_clock` (recorded as UTC)
- kdb: `.z.p`

**Trust:** Depends on clock synchronisation quality.

## Clock Synchronisation Trust Model

### Trust Rules

| Deployment | Clock Sync | Monotonic Latencies | Cross-Process Latencies |
|------------|------------|---------------------|------------------------|
| Single host (development) | N/A | ✓ Trusted | ✓ Acceptable (indicative) |
| Multi-host, NTP | NTP | ✓ Trusted | ✓ Trusted for millisecond-class |
| Multi-host, PTP | PTP (IEEE 1588) | ✓ Trusted | ✓ Trusted for sub-millisecond |
| Multi-host, no sync | None | ✓ Trusted | ✗ Unreliable |

### Trust Decision Matrix

| Segment | Clock Type | Single Host | Multi-Host NTP | Multi-Host PTP |
|---------|------------|-------------|----------------|----------------|
| `fh_parse_us` | Monotonic | ✓ | ✓ | ✓ |
| `fh_send_us` | Monotonic | ✓ | ✓ | ✓ |
| `market_to_fh_ms` | Wall-clock | Indicative | Indicative | Indicative |
| `fh_to_tp_ms` | Wall-clock | ✓ | ✓ | ✓ |
| `tp_to_rdb_ms` | Wall-clock | ✓ | ✓ | ✓ |
| `e2e_to_rdb_ms` | Wall-clock | ✓ | ✓ | ✓ |

Notes:
- `market_to_fh_ms` is always "indicative" because Binance clock is outside our control
- Negative values for `market_to_fh_ms` indicate clock misalignment (expected)

### Clock Quality Monitoring

When running multi-host deployments:

| Metric | Source | Threshold |
|--------|--------|-----------|
| NTP offset | `chronyc tracking` or `ntpq -p` | < 5ms for millisecond trust |
| NTP sync state | `chronyc tracking` | Must be synchronised |
| PTP offset | `ptp4l` logs | < 100µs for sub-millisecond trust |

If clock offset exceeds threshold:
- Cross-host E2E latency measurements should be flagged as unreliable
- Rely on per-segment monotonic metrics instead
- Log warning for operational visibility

## SLO Expression

### Target Percentiles

| Percentile | Purpose | Description |
|------------|---------|-------------|
| p50 | Typical latency | Median; what most requests experience |
| p95 | Majority-case tail | 95th percentile; captures most tail latency |
| p99 | Operationally significant tail | 99th percentile; important for SLO compliance |
| max | Spike detection | Maximum observed; identifies outliers |

### Rolling Windows

| Window | Purpose | Use Case |
|--------|---------|----------|
| 1-minute | Incident detection | Real-time alerting, anomaly detection |
| 15-minute | Trend analysis | Stable trend, capacity planning |

### SLO Scope

SLOs should explicitly state:

| Dimension | Current Scope |
|-----------|---------------|
| Message types | Trades only |
| Symbol universe | BTCUSDT, ETHUSDT |
| Recovery bursts | Excluded (no recovery mechanism per ADR-006) |

### Example SLO Statements
```
FH parse latency p99 < 100µs over 1-minute rolling window
FH send latency p99 < 50µs over 1-minute rolling window
E2E to RDB p99 < 10ms over 1-minute rolling window (single host)
```

## Aggregation Strategy

Latency measurements are aggregated per ADR-005:

| Parameter | Value |
|-----------|-------|
| Bucket size | 1 second |
| Percentiles computed | p50, p95, p99, max |
| Rolling windows | 1-minute, 15-minute |
| Aggregation location | RDB |
| Retention | 15 minutes (ephemeral) |

See ADR-005 for telemetry table schemas.

## Correlation and Gap Detection

### Correlation Fields

| Field | Purpose | Scope |
|-------|---------|-------|
| `fhSeqNo` | FH-level ordering and gap detection | Per FH instance |
| `tradeId` | Binance trade identification | Per symbol (from Binance) |
| `sym` | Symbol grouping | BTCUSDT, ETHUSDT |

### Gap Detection

| Gap Type | Detection Method | Recovery |
|----------|------------------|----------|
| FH sequence gap | `fhSeqNo` not contiguous | None (ADR-006) |
| Trade ID gap | `tradeId` not contiguous | None; Binance doesn't guarantee contiguous |
| Time gap | Large jump in `exchEventTimeMs` | None |

Gaps are detected and observable via telemetry but not recoverable (ADR-006).

### Uniqueness Key

Primary uniqueness for trade events: `(sym, tradeId)`

Used for:
- Deduplication (if reconnect/replay occurs)
- Correlation across system components

## Binance-Specific Considerations

### Trade Stream Fields

Binance trade stream (`<symbol>@trade`) provides:

| Field | JSON Key | Description |
|-------|----------|-------------|
| Event type | `e` | Always `"trade"` |
| Event time | `E` | Server event time (ms since epoch) |
| Symbol | `s` | e.g., `"BTCUSDT"` |
| Trade ID | `t` | Unique trade identifier |
| Price | `p` | Trade price (string) |
| Quantity | `q` | Trade quantity (string) |
| Trade time | `T` | Trade execution time (ms since epoch) |
| Buyer is maker | `m` | Boolean |

### Timestamp Characteristics

| Aspect | Behaviour |
|--------|-----------|
| `E` vs `T` | Often equal for trades; both server-side |
| Clock source | Binance server time |
| Precision | Milliseconds |
| Sync to local | Not synchronised; expect skew |

### Reconnect Behaviour

| Aspect | Behaviour |
|--------|-----------|
| Historical replay | Not provided on WebSocket reconnect |
| Gap recovery | Not available; data during disconnect is lost |
| Trade ID continuity | Not guaranteed to be contiguous |

## Implementation Checklist

### Feed Handler (C++)

- [ ] Capture `fhRecvTimeUtcNs` using `std::chrono::system_clock`
- [ ] Capture monotonic start time using `std::chrono::steady_clock`
- [ ] Compute `fhParseUs` after parse/normalise
- [ ] Compute `fhSendUs` after IPC send initiation
- [ ] Increment `fhSeqNo` per published message
- [ ] Extract `E`, `T`, `t` from Binance JSON

### Tickerplant (q)

- [ ] Capture `tpRecvTimeUtc` in `.z.ps` handler using `.z.p`
- [ ] Pass timestamp to downstream with trade data

### RDB (q)

- [ ] Capture `rdbApplyTimeUtc` after `upd` completes
- [ ] Store all timestamp fields in `trade_binance` table
- [ ] Compute telemetry aggregations on 1-second timer

### RTE (q)

- [ ] Capture `rteRecvTimeUtc` on update receipt (optional)
- [ ] Capture `rteComputeUs` for analytics duration (optional)
- [ ] Capture `rtePublishTimeUtc` when analytics ready (optional)

## Links / References

- `kdbx-real-time-architecture-reference.md`
- `adr-001-timestamps-and-latency-measurement.md` (authoritative field definitions)
- `adr-002-feed-handler-to-kdb-ingestion-path.md` (FH to TP path)
- `adr-003-tickerplant-logging-and-durability-strategy.md` (no TP logging)
- `adr-004-real-time-rolling-analytics-computation.md` (RTE measurement points)
- `adr-005-telemetry-and-metrics-aggregation-strategy.md` (aggregation strategy)
- `adr-006-recovery-and-replay-strategy.md` (gap detection without recovery)
- `adr-007-visualisation-and-consumption-strategy.md` (latency dashboard display)