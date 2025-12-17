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
| price | real | Trade price (64-bit floating point). |
| qty | real | Trade quantity (64-bit floating point). |
| buyerIsMaker | boolean | Binance `m` (`1b` if buyer is market maker). |
| exchEventTimeMs | long | Binance `E` (event time, ms since epoch). |
| exchTradeTimeMs | long | Binance `T` (trade time, ms since epoch). |
| fhRecvTimeUtcNs | long | Feed handler wall-clock receive time (ns since Unix epoch, UTC). |


## Timestamp Semantics
- exchEventTimeMs/exchTradeTimeMs: upstream times; used for market-to-fh estimates and correlation.
- fhRecvTimeUtcNs: FH wall-clock correlation time; may be impacted by clock sync quality across hosts.
- time: Tickerplant receive time (.z.p) used as platform-ingest time for windowing and intraday analytics.

## Notes

- Numeric types:
  - `price` and `qty` are stored as q `real` (64-bit floating point).
  - Binance provides these fields as JSON strings; they are parsed and normalised to numeric values in the feed handler before publication.

- Timing data:
  - Feed-handler monotonic durations (e.g. parse and send timings) are not stored per-event in this table.
  - Performance measurements are emitted to dedicated telemetry aggregates to avoid polluting core market data tables.

- Keying:
  - The uniqueness key (`sym`, `tradeId`) supports deduplication during reconnect and replay scenarios.

