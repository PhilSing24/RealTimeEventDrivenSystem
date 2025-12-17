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

### Columns (proposed)
| Column | Type | Description |
|---|---|---|
| time | timestamp | Tickerplant receive time (`.z.p`) when the update is accepted/logged and published. |
| sym | symbol | Normalised symbol (e.g., `BTCUSDT`) |
| tradeId | long | Binance trade id (`t`) |
| price | float | Trade price |
| qty | float | Trade quantity |
| buyerIsMaker | boolean | Binance `m` |
| exchEventTimeMs | long | Binance `E` (ms since epoch) |
| exchTradeTimeMs | long | Binance `T` (ms since epoch) |
| fhRecvTimeUtcNs | long | Feed handler wall-clock receive time (ns since epoch) |

## Timestamp Semantics
- exchEventTimeMs/exchTradeTimeMs: upstream times; used for market-to-fh estimates and correlation.
- fhRecvTimeUtcNs: FH wall-clock correlation time; may be impacted by clock sync quality across hosts.
- time: Tickerplant receive time (.z.p) used as platform-ingest time for windowing and intraday analytics.

## Notes
- Feed-handler monotonic durations (fhParseUs, fhSendUs) are not stored per-event in this table; they are emitted to telemetry aggregates.
## Notes
- Numeric types: `price` and `qty` are stored as q `float` (64-bit). Binance provides these fields as JSON strings; they are parsed to numeric in the feed handler and stored numerically in kdb.

