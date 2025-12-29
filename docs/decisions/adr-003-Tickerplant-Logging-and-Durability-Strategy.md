# ADR-003: Tickerplant Logging and Durability Strategy

## Status
Accepted (Updated 2025-12-29)

## Date
2025-12-17 (Updated 2025-12-29)

## Context

In a canonical kdb real-time architecture, the tickerplant (TP) is responsible for:

- Sequencing inbound events
- Publishing updates to real-time databases (RDBs)
- Optionally providing a durability boundary via logging

This project ingests real-time Binance market data:
- Trade data via WebSocket trade stream
- Quote data via WebSocket depth stream with REST snapshot reconciliation

A key design decision is whether and how the tickerplant should log incoming updates.

## Notation

| Acronym | Definition |
|---------|------------|
| FH | Feed Handler |
| HDB | Historical Database |
| IPC | Inter-Process Communication |
| RDB | Real-Time Database |
| RTE | Real-Time Engine |
| TP | Tickerplant |

## Decision

The tickerplant logs incoming updates to **separate binary log files** per data type.

### Log File Structure
```
logs/
  2025.12.29.trade.log   # Trade events only
  2025.12.29.quote.log   # Quote events only
```

### Log File Naming

| Data Type | Pattern | Example |
|-----------|---------|---------|
| Trades | `YYYY.MM.DD.trade.log` | `2025.12.29.trade.log` |
| Quotes | `YYYY.MM.DD.quote.log` | `2025.12.29.quote.log` |

### Logging Configuration
```q
.tp.cfg.logEnabled:1b;
.tp.cfg.logDir:"logs";
```

### Implementation

The TP maintains separate file handles:
```q
.tp.tradeLogHandle   / Handle for trade log
.tp.quoteLogHandle   / Handle for quote log
```

Routing logic in `.tp.log`:
```q
.tp.log:{[tbl;data]
  if[not .tp.cfg.logEnabled; :()];
  $[tbl = `trade_binance;
    .tp.tradeLogHandle enlist (`.u.upd; tbl; data);
    .tp.quoteLogHandle enlist (`.u.upd; tbl; data)
  ];
  };
```

### Rationale for Separate Files

| Benefit | Description |
|---------|-------------|
| Independent replay | Replay trades without quotes or vice versa |
| Different consumers | RTE only needs trades |
| Debugging | Isolate issues to specific data type |
| Retention | Could have different retention policies |
| Size management | Trade and quote volumes differ |

### End-of-Day Behaviour

- Log rotation occurs at midnight (new date = new files)
- `.tp.rotate[]` function closes old handles, opens new
- No Historical Database (HDB) implemented
- Logs are retained for replay/debugging but not persisted to HDB

### Downstream Recovery Implications

| Component | On Restart | Recovery Source |
|-----------|------------|-----------------|
| RDB | Starts empty | Replay from trade log |
| RTE | State lost | Replay from trade log |
| TP | Logs reset | N/A |

### Tables Logged

| Table | Log File | Subscribers |
|-------|----------|-------------|
| `trade_binance` | `.trade.log` | RDB, RTE |
| `quote_binance` | `.quote.log` | (TP only currently) |

## Rationale

Separate log files were selected because:

- **Replay flexibility**: Can replay trades to RTE without quote noise
- **Consumer alignment**: RDB/RTE only subscribe to trades currently
- **Debugging**: Easier to isolate issues per data type
- **Future-proof**: Different retention or archival policies possible

## Alternatives Considered

### 1. Single combined log file
Rejected:
- Must replay everything to get anything
- Larger files to scan
- Mixed data types complicate debugging

### 2. No logging (original design)
Updated:
- Logging now enabled by default
- Provides replay capability
- Minimal latency impact

### 3. Per-symbol log files
Rejected:
- Too many files (2 symbols x 2 types = 4 files)
- Complicates replay
- Overkill for current scale

### 4. Separate logger process
Rejected:
- Adds complexity
- TP can handle logging efficiently
- Not needed at current scale

## Consequences

### Positive

- Independent replay per data type
- Cleaner debugging
- Flexible recovery options
- Minimal latency impact
- Simple implementation

### Negative / Trade-offs

- Two file handles to manage
- Log rotation must handle both files
- Slightly more complex than single file

These trade-offs are acceptable.

## Replay Support

Replay tool (`kdb/replay.q`) supports targeting specific log types:
```bash
# Replay trades only
q kdb/replay.q -logfile logs/2025.12.29.trade.log

# Replay quotes only
q kdb/replay.q -logfile logs/2025.12.29.quote.log
```

## Links / References

- `../kdbx-real-time-architecture-reference.md`
- `adr-006-recovery-and-replay-strategy.md` (replay mechanism)
- `adr-009-l1-order-book-architecture.md` (quote data source)