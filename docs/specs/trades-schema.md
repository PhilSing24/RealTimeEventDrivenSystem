# Spec: Binance Trades Schema (Canonical)

## Purpose
Define the canonical schema for Binance trade events as stored in kdb+/KDB-X, including keys, types, and timestamp semantics.

## Naming
- Tables: snake_case (e.g., `trade_binance`)
- Columns: lowerCamelCase (e.g., `exchTradeTimeMs`, `buyerIsMaker`)
- All timestamps are UTC; units are encoded in the field name (Ms, Ns, Us).

## Source Event (Binance)
Relevant fields:
- e (event type)
- E (event time, ms since epoch)
- T (trade time, ms since epoch)
- s (symbol)
- t (trade id)
- p (price)
- q (quantity)
- m (buyer is maker)

## Target Table
### Table name
`trade_binance`

### Key / Uniqueness
Primary uniqueness key: (`sym`, `tradeId`)

### Columns
| Column | Type | Description |
|---|---|---|
| time | timestamp | Tickerplant receive time (`.z.p`) when the update is accepted/logged and published. |
| sym | symbol | Normalised symbol (e.g., `BTCUSDT`). Conventional lowercase naming retained for kdb idioms. |
| tradeId | long | Binance trade id (`t`). Unique per symbol. |
| price | float | Trade price (64-bit floating point). |
| qty | float | Trade quantity (64-bit floating point). |
| buyerIsMaker | boolean | Binance `m` (`1b` if buyer is market maker). |
| exchEventTimeMs | long | Binance `E` (event time, ms since epoch). |
| exchTradeTimeMs | long | Binance `T` (trade time, ms since epoch). |
| fhRecvTimeUtcNs | long | Feed handler wall-clock receive time (ns since Unix epoch, UTC). |
| fhParseUs | long | Feed handler parse/normalise duration (microseconds, monotonic-derived). |
| fhSendUs | long | Feed handler send preparation duration (microseconds, monotonic-derived). |
| fhSeqNo | long | Feed handler sequence number (monotonically increasing per FH instance). |
| tpRecvTimeUtcNs | long | Tickerplant receive time (ns since Unix epoch, UTC). |
| rdbApplyTimeUtcNs | long | RDB apply time when update becomes query-consistent (ns since Unix epoch, UTC). |

## Timestamp Semantics

### Upstream timestamps
- `exchEventTimeMs` / `exchTradeTimeMs`: Binance server-side times; used for market-to-FH estimates and correlation.

### Feed handler timestamps
- `fhRecvTimeUtcNs`: Wall-clock correlation time (nanoseconds since epoch, UTC). May be impacted by clock sync quality across hosts.
- `fhParseUs`: Duration from message receipt to parse/normalise completion. Derived from monotonic clock; always trusted.
- `fhSendUs`: Duration from parse completion to IPC send initiation. Derived from monotonic clock; always trusted.
- `fhSeqNo`: Sequence number for gap detection and ordering diagnostics.

### Platform timestamps
- `time`: Tickerplant receive time (`.z.p`) used as platform-ingest time for windowing and intraday analytics.
- `tpRecvTimeUtcNs`: Same as `time` but expressed as nanoseconds since Unix epoch for latency calculations.
- `rdbApplyTimeUtcNs`: RDB apply time; marks when the trade is query-consistent. Used for TP-to-RDB and end-to-end latency.

## Latency Calculations

With all timestamps in place, the following latencies can be computed:

| Metric | Formula | Description |
|--------|---------|-------------|
| `fh_parse_us` | `fhParseUs` | FH parse/normalise duration (direct) |
| `fh_send_us` | `fhSendUs` | FH send prep duration (direct) |
| `fh_to_tp_ms` | `(tpRecvTimeUtcNs - fhRecvTimeUtcNs) / 1e6` | FH to TP latency |
| `tp_to_rdb_ms` | `(rdbApplyTimeUtcNs - tpRecvTimeUtcNs) / 1e6` | TP to RDB latency |
| `e2e_ms` | `(rdbApplyTimeUtcNs - fhRecvTimeUtcNs) / 1e6` | End-to-end system latency |

## Notes

- **Numeric types:**
  - `price` and `qty` are stored as q `float` (64-bit floating point).
  - Binance provides these fields as JSON strings; they are parsed and normalised to numeric values in the feed handler before publication.

- **Timing data:**
  - Per-event latency fields are stored in this table to enable debugging and correlation.
  - Aggregated telemetry (percentiles, rolling windows) is computed in the RDB and stored in separate telemetry tables (see ADR-005).

- **Keying:**
  - The uniqueness key (`sym`, `tradeId`) supports deduplication during reconnect and replay scenarios.

- **Sequence numbers:**
  - `fhSeqNo` is assigned by the feed handler and increments per published message.
  - Gaps in `fhSeqNo` indicate dropped messages at the feed handler level.
  - `fhSeqNo` resets to 0 on feed handler restart.

- **Schema differences:**
  - TP schema has 13 columns (excludes `rdbApplyTimeUtcNs`)
  - RDB schema has 14 columns (includes `rdbApplyTimeUtcNs`)
  - RDB appends `rdbApplyTimeUtcNs` when it receives data from TP

## Telemetry Tables

See ADR-005 for telemetry table schemas. Summary:

| Table | Description |
|-------|-------------|
| `telemetry_latency_fh` | FH segment latencies (p50/p95/p99/max) per 1-second bucket |
| `telemetry_latency_e2e` | Cross-process latencies (p50/p95/p99) per 1-second bucket |
| `telemetry_throughput` | Trade counts and volumes per 1-second bucket |
