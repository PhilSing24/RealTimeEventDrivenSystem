# ADR-001: Timestamps and Latency Measurement

## Status
Accepted

## Date
2025-12-17

## Context
This project ingests real-time Binance market data via WebSocket (JSON), normalises it in a high-performance C++ feed handler (Boost.Beast + RapidJSON), and publishes it into a kdb+/KDB-X environment (tickerplant/RDB) via IPC (kdb+ C API).

We need consistent timestamping to:
- Measure latency within the feed handler reliably (parsing, normalisation, IPC send).
- Estimate end-to-end latency through the kdb pipeline.
- Correlate events across components (FH, TP, RDB, downstream).
- Support debugging during reconnect/recovery scenarios.

Binance events include upstream timestamps:
- `E`: event time (ms since epoch, exchange/server-side)
- `T`: trade time (ms since epoch, exchange-side)

For trade events, `T` and `E` may be equal but are treated as distinct fields.

## Notation

| Acronym | Definition |
|---------|------------|
| FH | Feed Handler |
| IPC | Inter-Process Communication |
| NTP | Network Time Protocol |
| PTP | Precision Time Protocol (IEEE 1588) |
| RDB | Real-Time Database |
| RTE | Real-Time Engine |
| SLO | Service-Level Objective |
| TP | Tickerplant |
| UTC | Coordinated Universal Time |

## Decision

### 1) Clock Types
We use two clock concepts:

- **Monotonic time** (duration clock): for measuring intra-process durations in the C++ feed handler.
  - C++: `std::chrono::steady_clock`
  - Rationale: monotonic time never moves backwards and is not affected by NTP/PTP adjustments.

- **Wall-clock time** (UTC/calendar): for cross-process correlation between FH and kdb components.
  - C++: `std::chrono::system_clock` (recorded as UTC)
  - kdb: `.z.p` for process-side wall-clock timestamps
  - Rationale: wall-clock time is comparable across processes/hosts when clock sync quality is acceptable.

### 2) Timestamp Fields Captured
For each inbound event (e.g., trade) the feed handler captures:

**Upstream (from Binance message):**

| Field | Source | Unit |
|-------|--------|------|
| `exchEventTimeMs` | `E` | milliseconds since epoch |
| `exchTradeTimeMs` | `T` | milliseconds since epoch |
| `tradeId` | `t` | integer |

**Feed handler wall-clock (UTC):**

| Field | Description | Unit |
|-------|-------------|------|
| `fhRecvTimeUtcNs` | Wall-clock timestamp when WebSocket message is available to process | nanoseconds since epoch |

**Feed handler monotonic timing (durations):**

| Field | Description | Unit |
|-------|-------------|------|
| `fhParseUs` | Duration from receive to completion of JSON parse + normalisation | microseconds |
| `fhSendUs` | Duration from completion of parse/normalisation to IPC send initiation | microseconds |

Notes:
- Monotonic instants are not stored as absolute values; only derived durations are recorded.
- Durations are stored in microseconds for practical precision without excessive storage overhead.

**Feed handler sequence number:**

| Field | Description | Unit |
|-------|-------------|------|
| `fhSeqNo` | Monotonically increasing sequence number per feed handler instance | integer |

The sequence number is recommended (not optional) because it:
- Supports gap detection during normal operation
- Aids replay validation if recovery is later introduced (see ADR-006)
- Provides ordering diagnostics independent of exchange IDs
- Has negligible implementation cost

**kdb-side timestamps:**

| Field | Description | Unit |
|-------|-------------|------|
| `tpRecvTimeUtc` | TP receive time captured at ingest (`.z.p`) | kdb timestamp |
| `rdbApplyTimeUtc` | Time the update becomes query-consistent in the RDB | kdb timestamp |

### 3) Schema Hygiene
To avoid polluting core market-data tables with excessive timing columns:

**Market data table (e.g., `trade_binance`) stores:**
- `exchEventTimeMs`
- `exchTradeTimeMs`
- `fhRecvTimeUtcNs`
- `fhSeqNo`
- `tradeId`
- Normalised business fields (sym, price, qty, side, etc.)
- `tpRecvTimeUtc`

**Telemetry table (e.g., `telemetry_latency_fh`) stores aggregated metrics:**
- Time bucket (e.g., per-second)
- Event counts
- Latency percentiles for `fhParseUs` and `fhSendUs`
- Max values for spike detection

Rationale: store per-event wall-clock once (for correlation), but store performance metrics in aggregated form to manage volume.

### 4) Latency Metrics Definitions

**Feed handler segment latencies (monotonic-derived, always trusted):**

| Metric | Definition |
|--------|------------|
| `fh_parse_us` | Feed handler parse/normalise duration |
| `fh_send_us` | Feed handler post-parse to IPC send initiation |

**Cross-process latencies (wall-clock-derived, trust depends on clock sync):**

| Metric | Definition | Notes |
|--------|------------|-------|
| `market_to_fh_ms` | `(fhRecvTimeUtcNs / 1,000,000) - exchEventTimeMs` | Indicative only; includes network + exchange semantics; may be negative if clocks are misaligned |
| `fh_to_tp_ms` | `tpRecvTimeUtc - fhRecvTimeUtc` | Requires unit conversion |
| `tp_to_rdb_ms` | `rdbApplyTimeUtc - tpRecvTimeUtc` | |
| `e2e_system_ms` | `rdbApplyTimeUtc (or rtePublishTime) - fhRecvTimeUtc` | Full system latency |

### 5) SLO Expression and Aggregation Windows

Latency SLOs are expressed using percentiles over rolling windows.

**Target percentiles:**

| Percentile | Purpose |
|------------|---------|
| p50 | Typical latency (median) |
| p95 | Majority-case tail |
| p99 | Operationally significant tail |

**Rolling windows:**

| Window | Purpose |
|--------|---------|
| 1-minute | Incident detection, real-time alerting |
| 15-minute | Stable trend analysis, capacity planning |

SLOs should explicitly state:
- Which message types are included (trades only, initially)
- Which symbol universe is included (BTCUSDT, ETHUSDT initially)
- Whether reconnect/recovery bursts are included or excluded

### 6) Clock Synchronisation Trust Model

- Segment latencies derived from monotonic time are **always trusted**.
- Cross-host end-to-end latency derived from wall-clock is **only trusted if clock sync quality is acceptable**.

**Trust rules:**

| Deployment | Clock Sync | Cross-host E2E Trust |
|------------|------------|----------------------|
| Single host (development) | N/A | Acceptable; indicative |
| Multi-host, NTP | NTP | Trusted for millisecond-class reporting |
| Multi-host, PTP | PTP | Required for sub-millisecond precision |

**Clock quality monitoring:**
- Clock quality telemetry SHOULD be captured when running multi-host (e.g., NTP/chrony tracking offset).
- If clock offset exceeds a defined threshold (e.g., >5ms), cross-host end-to-end latency measurements should be flagged as unreliable.
- When cross-host latency is unreliable, rely on segment metrics instead.

### 7) Correlation and Deduplication

**Primary uniqueness key for trade events:**
- (`sym`, `tradeId`)

**Deduplication behaviour:**
- If reconnect/replay occurs, duplicates are detected by the primary key.
- `fhSeqNo` provides additional ordering context for diagnostics.

**Gap detection:**
- `fhSeqNo` gaps indicate missed events at the feed handler level.
- `tradeId` gaps (per symbol) may indicate missed events at the exchange level, though Binance does not guarantee contiguous trade IDs.

## Consequences

### Positive
- Reliable feed handler latency measurement independent of wall-clock adjustments.
- Clear separation between correlation timestamps (wall-clock) and performance timings (monotonic durations).
- Market data schema remains clean; performance monitoring scales via telemetry aggregates.
- Explicit SLO percentiles and windows provide clear targets for measurement.
- Sequence numbers support future recovery/replay without schema changes.

### Negative / Trade-offs
- End-to-end latency across hosts can be misleading without good clock sync; requires explicit trust rules and monitoring.
- Additional instrumentation effort in both FH and TP/RDB.
- Telemetry aggregation provides less per-event detail (by design).
- Sequence number adds a small amount of state to the feed handler.

## Links / References
- `../kdbx-real-time-architecture-reference.md`
- `../kdbx-real-time-architecture-measurement-notes.md`
- `../api-binance.md`
- `adr-005-telemetry-and-metrics-aggregation-strategy.md` (for telemetry aggregation details)
- `adr-006-recovery-and-replay-strategy.md` (for recovery deferral context)