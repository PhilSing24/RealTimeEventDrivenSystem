# ADR-009: L1 Order Book Architecture

## Status
Accepted

## Date
2025-12-29

## Context

The system ingests real-time trade data from Binance. To support trading strategies and market analysis, L1 (best bid/ask) quote data is also required.

Binance provides order book data via two mechanisms:
1. REST API snapshot (`/api/v3/depth`)
2. WebSocket delta stream (`@depth`)

Neither alone is sufficient:
- Snapshots become stale immediately
- Deltas require a baseline to apply against

Binance specifies a reconciliation protocol:
1. Buffer deltas from WebSocket
2. Fetch REST snapshot
3. Apply buffered deltas with sequence validation
4. Continue applying live deltas

A decision is required on how to implement L1 quote ingestion with correct reconciliation.

## Notation

| Acronym | Definition |
|---------|------------|
| FH | Feed Handler |
| L1 | Level 1 (best bid/ask only) |
| L5 | Level 5 (top 5 price levels) |
| TP | Tickerplant |

## Decision

L1 quotes are ingested via a dedicated Quote Feed Handler process that implements snapshot + delta reconciliation with a state machine.

### Process Architecture

**Separate process (not integrated into Trade FH):**

| Aspect | Trade FH | Quote FH |
|--------|----------|----------|
| Data source | `@trade` stream | `@depth` stream + REST |
| Complexity | Simple (no state) | Complex (book state, reconciliation) |
| Failure mode | Independent | Independent |
| Restart | No impact on quotes | No impact on trades |

Rationale:
- Single responsibility principle
- Independent failure and restart
- Simpler debugging (separate logs)
- No threading required

### State Machine
```
INIT --> SYNCING --> VALID <--> INVALID
  ^                    |           |
  |                    v           |
  +--------------------+-----------+
         (rebuild on gap)
```

| State | Description | Transitions |
|-------|-------------|-------------|
| INIT | No data, buffering deltas | Start snapshot fetch -> SYNCING |
| SYNCING | Snapshot received, applying buffered deltas | Valid delta -> VALID |
| VALID | Book consistent, publishing L1 | Sequence gap -> INVALID |
| INVALID | Sequence gap detected | Reset -> INIT |

### Sequence Validation

Per Binance specification:

**First delta after snapshot:**
- Must satisfy: `U <= lastUpdateId + 1 <= u`
- Where `U` = first update ID, `u` = final update ID, `lastUpdateId` = snapshot ID

**Subsequent deltas:**
- Must satisfy: `U == lastUpdateId + 1`
- Any gap triggers immediate invalidation

### Internal Depth vs Publication Depth

| Aspect | Value | Rationale |
|--------|-------|-----------|
| Internal book depth | L5 (5 levels) | Buffer for delta application |
| Published depth | L1 (best only) | Sufficient for current use cases |
| REST snapshot request | 50 levels | Ensure coverage during reconciliation |

L5 internal depth provides margin for delta application without risking empty books. Publication is L1 only to minimize bandwidth and storage.

### Publication Discipline

**Publish triggers:**
1. Best bid price or quantity changes
2. Best ask price or quantity changes
3. Validity state changes (VALID -> INVALID or vice versa)
4. Timeout (50ms) with no change

**Publication rules:**
- Only publish on actual L1 change, not every delta
- Publish explicit invalid state once, then stop until valid
- Downstream can trust `isValid` flag blindly

Rationale:
- Reduces noise (not every delta affects L1)
- Protects downstream from stale data
- 50ms timeout ensures staleness detection

### Invalid State Handling

When sequence gap detected:
1. Mark book INVALID immediately
2. Publish one invalid quote (`isValid = false`, prices = 0)
3. Stop publishing until rebuilt
4. Reset to INIT state
5. Re-request snapshot on next delta

Downstream consumers see explicit invalid state and can react appropriately.

### Schema

**quote_binance table (11 fields):**

| Column | Type | Source | Description |
|--------|------|--------|-------------|
| `time` | timestamp | FH | FH receive time (kdb epoch) |
| `sym` | symbol | Binance | Trading symbol |
| `bidPx` | float | FH | Best bid price |
| `bidQty` | float | FH | Best bid quantity |
| `askPx` | float | FH | Best ask price |
| `askQty` | float | FH | Best ask quantity |
| `isValid` | boolean | FH | Book validity flag |
| `exchEventTimeMs` | long | Binance | Exchange event time |
| `fhRecvTimeUtcNs` | long | FH | Wall-clock receive (ns) |
| `fhSeqNo` | long | FH | FH sequence number |
| `tpRecvTimeUtcNs` | long | TP | TP receive time (ns) |

### Logging

Separate log files per ADR-003:
- Trade log: `logs/YYYY.MM.DD.trade.log`
- Quote log: `logs/YYYY.MM.DD.quote.log`

Rationale:
- Independent replay
- Cleaner debugging
- Different retention policies possible

### REST Client

Synchronous HTTPS client for snapshot fetch:
- Uses Boost.Beast (already a dependency)
- Blocking call during INIT state
- Fetches 50 levels (configurable)
- Parses JSON response

Trade-off: Blocking snapshot fetch is acceptable because:
- Only occurs on startup and after gaps
- Simpler than async implementation
- Gaps are rare in normal operation

## Rationale

This approach was selected because:

- **Correctness**: Snapshot + delta reconciliation is the only way to build accurate books
- **Explicit validity**: Downstream never sees silently stale data
- **Separation**: Quote FH failure doesn't affect trade ingestion
- **Simplicity**: State machine is clear and testable
- **Extensibility**: L5 internal depth allows easy upgrade to L5 publication

## Alternatives Considered

### 1. Integrate into Trade FH (single process)
Rejected:
- Requires threading or async complexity
- Single failure domain
- Mixed concerns

### 2. Use `@depth@100ms` throttled stream
Rejected:
- Still requires snapshot reconciliation
- Higher latency (100ms batches)
- No simplification of reconciliation logic

### 3. Poll REST snapshots only
Rejected:
- High latency (minimum practical poll ~1s)
- Rate limit concerns
- Not real-time

### 4. Trust deltas without validation
Rejected:
- Silent corruption on gaps
- Violates "strategy must trust book blindly" principle
- Debugging nightmare

### 5. Publish every delta
Rejected:
- Most deltas don't change L1
- Unnecessary downstream load
- Publication should reflect meaningful changes

## Consequences

### Positive

- Correct book state guaranteed by reconciliation
- Explicit validity for downstream trust
- Independent process lifecycle
- Clear state machine for debugging
- L5 ready for future extension
- Separate logs for independent analysis

### Negative / Trade-offs

- Two processes to manage instead of one
- REST snapshot introduces brief blocking
- More complex than trade-only system
- Sequence gaps require full rebuild (no partial recovery)

These trade-offs are acceptable for correct L1 data.

## Implementation

| Component | File | Purpose |
|-----------|------|---------|
| OrderBook | `src/order_book.hpp` | State machine, book maintenance |
| L1Publisher | `src/order_book.hpp` | Publication decision logic |
| RestClient | `src/rest_client.hpp` | Snapshot fetching |
| QuoteHandler | `src/quote_handler.hpp` | WebSocket, reconciliation |
| Main | `src/quote_handler_main.cpp` | Entry point |

## Future Evolution

| Enhancement | Trigger |
|-------------|---------|
| L5 publication | Strategy requirement |
| Async snapshot fetch | Latency sensitivity |
| Multiple symbol batching | Scale to 100+ symbols |
| Reconnect hardening | Production deployment |

## Links / References

- `../kdbx-real-time-architecture-reference.md`
- `../api-binance.md` (depth stream specification)
- `adr-002-feed-handler-to-kdb-ingestion-path.md` (trade FH design)
- `adr-003-tickerplant-logging-and-durability-strategy.md` (separate log files)
- `adr-008-error-handling-strategy.md` (reconnect, error handling)