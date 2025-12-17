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
- `exchEventTimeMs` = `E`
- `exchTradeTimeMs` = `T`
- `tradeId` = `t` (for trade events)

**Feed handler wall-clock (UTC):**
- `fhRecvTimeUtcNs` : wall-clock receive timestamp (nanoseconds since epoch), taken when the full WebSocket message is available to process.

**Feed handler monotonic timing (durations):**
- `fhParseUs`  : microseconds from receive to completion of JSON parse + normalisation.
- `fhSendUs`   : microseconds from completion of parse/normalisation to IPC send initiation.
Notes:
- Monotonic instants are not stored as absolute values; only derived durations are recorded (microseconds).

**kdb-side timestamps (optional but recommended):**
- `tpRecvTime` : TP receive time captured at ingest (`.z.p`) if/when implemented.
- `rdbApplyTime` : time the update becomes query-consistent in the RDB (optional; may be approximated via `tpRecvTime` initially).

### 3) What Gets Stored Where (Schema Hygiene)
To avoid polluting core market-data tables with excessive timing columns:

**Market data table (e.g., `trade_binance`) stores:**
- `exchEventTimeMs` (E)
- `exchTradeTimeMs` (T)
- `fhRecvTimeUtcNs`
- `tradeId`
- normalised business fields (sym, price, qty, side, etc.)
Optional (only if needed):
- `tpRecvTime` (for kdb-side visibility)

**Telemetry table (e.g., `telemetry_latency_fh`) stores aggregated metrics:**
- time bucket (e.g., per-second)
- counts (events/sec)
- latency percentiles for `fhParseUs` and `fhSendUs` (p50/p95/p99)
- max values for spike detection
Rationale: store per-event wall-clock once (for correlation), but store performance metrics in aggregated form.

### 4) Latency Metrics Definitions
We define:

- `market_to_fh_ms` = `fhRecvTimeUtcMs - exchEventTimeMs`
  - Indicative only; includes network + exchange semantics; may be negative if clocks are misaligned.

- `fh_parse_us` = feed handler parse/normalise duration (monotonic-derived).
- `fh_send_us`  = feed handler post-parse to IPC send initiation (monotonic-derived).

End-to-end (when kdb timestamps exist and clocks are trustworthy):
- `fh_to_tp_ms` = `tpRecvTime - fhRecvTimeUtc`
- `tp_to_rdb_ms` = `rdbApplyTime - tpRecvTime` (if captured)
- `e2e_system_ms` = `rdbApplyTime (or rtePublishTime) - fhRecvTimeUtc`

### 5) Clock Synchronisation Trust Model (NTP/PTP)
- Segment latencies derived from monotonic time are always trusted.
- Cross-host end-to-end latency derived from wall-clock is only trusted if clock sync quality is acceptable.

Initial stance:
- Development (single host): wall-clock correlation is acceptable; end-to-end is indicative.
- Multi-host deployments:
  - NTP is acceptable for millisecond-class reporting.
  - PTP is required for trustworthy sub-millisecond cross-host latency measurement.

Clock quality telemetry SHOULD be captured when running multi-host (e.g., NTP/chrony tracking offset), and end-to-end measurements flagged unreliable when offset exceeds an agreed threshold.

### 6) Correlation and Deduplication
For trade events:
- Primary uniqueness key: (`sym`, `tradeId`)
- If reconnect/replay occurs, duplicates are detected by this key.
Optional:
- Add `fhSeqNo` (monotonic integer) if we later need strict ordering diagnostics independent of exchange IDs.

## Consequences

### Positive
- Reliable feed handler latency measurement independent of wall-clock adjustments.
- Clear separation between correlation timestamps (wall-clock) and performance timings (monotonic durations).
- Market data schema remains clean; performance monitoring scales via telemetry aggregates.

### Negative / Trade-offs
- End-to-end latency across hosts can be misleading without good clock sync; requires explicit trust rules.
- Additional instrumentation effort in both FH and (optionally) TP/RDB.
- Telemetry aggregation introduces less per-event detail (by design).

## Links / References
- `../kdbx-real-time-architecture-reference.md`
- `../kdbx-real-time-architecture-measurement-notes.md`
- `../api-binance.md`
