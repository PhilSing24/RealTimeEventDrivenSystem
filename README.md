# Real-Time Event-Driven Market Data System

A real-time, event-driven Binance market data pipeline built with C++ and kdb+/KDB-X. Inspired by the article *Building Real-Time Event-Driven KDB-X Systems* by Data Intellect.

## Architecture
```
Binance ---WebSocket---> Trade FH ---IPC---> TP :5010 --+--> RDB :5011 (storage)
                                                       |
Binance ---WebSocket---> Quote FH ---IPC--->           +--> RTE :5012 (analytics)
```

| Component | Port | Role |
|-----------|------|------|
| TP | 5010 | Tickerplant - pub/sub, logging |
| RDB | 5011 | Real-Time Database - trade storage |
| RTE | 5012 | Real-Time Engine - rolling analytics |
| Trade FH | - | Trade feed handler - WebSocket to IPC |
| Quote FH | - | Quote feed handler - L1 book with snapshot reconciliation |

## What This Project Does

- Ingests **real-time trade data** from Binance (BTCUSDT, ETHUSDT)
- Ingests **real-time L1 quotes** with snapshot + delta reconciliation
- Captures **latency measurements** at every pipeline stage
- Publishes via **IPC** to a kdb+ tickerplant with pub/sub
- Stores trades with **full instrumentation** (14 timestamp/latency fields)
- Computes **rolling analytics** (5-minute average price, trade count)
- Logs to **separate files** for trades and quotes

## Quick Start
```bash
# Terminal 1: Start Tickerplant
q kdb/tp.q

# Terminal 2: Start RDB
q kdb/rdb.q

# Terminal 3: Start RTE
q kdb/rte.q

# Terminal 4: Build and run Trade Feed Handler
cmake -S . -B build
cmake --build build
./build/binance_feed_handler

# Terminal 5: Run Quote Feed Handler
./build/binance_quote_handler
```

Or use the tmux launcher:
```bash
./start.sh
```

## Verify It Works

**TP (port 5010)** - both trades and quotes:
```q
select count i by sym from trade_binance
select count i by sym from quote_binance
```

**RDB (port 5011)** - trades only:
```q
select count i by sym from trade_binance
select from -5#trade_binance
```

**RTE (port 5012)** - rolling analytics:
```q
rollAnalytics
/ isValid flips to 1b once window is 50% filled (~2.5 min)
```

## Configuration

### Adding/Removing Symbols

**Trade handler** - edit `src/feed_handler.cpp`:
```cpp
const std::vector<std::string> SYMBOLS = {
    "btcusdt",
    "ethusdt"
};
```

**Quote handler** - edit `src/quote_handler_main.cpp`:
```cpp
const std::vector<std::string> SYMBOLS = {
    "btcusdt",
    "ethusdt"
};
```

Rebuild and restart. No changes needed to kdb+ components.

### RTE Parameters

Edit `kdb/rte.q`:
```q
.rte.cfg.windowNs:5 * 60 * 1000000000j;  / Rolling window: 5 minutes
.rte.cfg.validityThreshold:0.5;          / 50% fill required for validity
```

## Data Flow
```
Trade FH ---> TP --+--> RDB (trade storage)
                   |
Quote FH -------->-+--> RTE (analytics)
                   |
                   +--> Log files
```

- RDB subscribes to `trade_binance` only
- RTE subscribes to `trade_binance` only
- TP logs both to separate files

## Log Files
```
logs/
  2025.12.29.trade.log   # Binary trade log
  2025.12.29.quote.log   # Binary quote log
```

## Tables

### trade_binance (14 fields)

| Field | Source | Description |
|-------|--------|-------------|
| `time` | FH | FH receive time as kdb timestamp |
| `sym` | Binance | Trading symbol |
| `tradeId` | Binance | Trade ID |
| `price` | Binance | Trade price |
| `qty` | Binance | Trade quantity |
| `buyerIsMaker` | Binance | Buyer is maker flag |
| `exchEventTimeMs` | Binance | Exchange event time |
| `exchTradeTimeMs` | Binance | Exchange trade time |
| `fhRecvTimeUtcNs` | FH | Wall-clock receive (ns) |
| `fhParseUs` | FH | Parse duration (us) |
| `fhSendUs` | FH | Send prep duration (us) |
| `fhSeqNo` | FH | Sequence number |
| `tpRecvTimeUtcNs` | TP | TP receive time (ns) |
| `rdbApplyTimeUtcNs` | RDB | RDB apply time (ns) |

### quote_binance (11 fields)

| Field | Source | Description |
|-------|--------|-------------|
| `time` | FH | FH receive time as kdb timestamp |
| `sym` | Binance | Trading symbol |
| `bidPx` | FH | Best bid price |
| `bidQty` | FH | Best bid quantity |
| `askPx` | FH | Best ask price |
| `askQty` | FH | Best ask quantity |
| `isValid` | FH | Book validity flag |
| `exchEventTimeMs` | Binance | Exchange event time |
| `fhRecvTimeUtcNs` | FH | Wall-clock receive (ns) |
| `fhSeqNo` | FH | Sequence number |
| `tpRecvTimeUtcNs` | TP | TP receive time (ns) |

## Rolling Analytics (RTE)

| Field | Description |
|-------|-------------|
| `lastPrice` | Most recent trade price |
| `avgPrice5m` | 5-minute rolling average price |
| `tradeCount5m` | 5-minute rolling trade count |
| `isValid` | True if window >= 50% filled |
| `fillPct` | Percentage of window with data |
| `windowStart` | Oldest trade time in window |
| `updateTime` | Last analytics update time |

## Quote Handler Features

- **Snapshot + delta reconciliation** per Binance spec
- **State machine**: INIT -> SYNCING -> VALID -> INVALID
- **Sequence validation**: gaps trigger rebuild
- **L1 publication**: only on price/qty change or 50ms timeout
- **Validity tracking**: `isValid` flag for downstream consumers

## Project Structure
```
.
├── CMakeLists.txt
├── src/
│   ├── main.cpp                  # Trade FH entry point
│   ├── feed_handler.cpp          # Trade WebSocket + IPC
│   ├── quote_handler_main.cpp    # Quote FH entry point
│   ├── quote_handler.hpp         # Quote WebSocket + reconciliation
│   ├── order_book.hpp            # OrderBook class + L1Publisher
│   ├── rest_client.hpp           # REST snapshot client
│   └── test_snapshot.cpp         # Snapshot test utility
├── kdb/
│   ├── tp.q                      # Tickerplant
│   ├── rdb.q                     # RDB - trade storage
│   └── rte.q                     # RTE - rolling analytics
├── third_party/kdb/
│   ├── k.h
│   └── c.o
├── start.sh
├── stop.sh
└── docs/
    ├── kdbx-real-time-architecture-reference.md
    ├── kdbx-real-time-architecture-measurement-notes.md
    ├── api-binance.md
    ├── specs/
    │   └── trades-schema.md
    └── decisions/
        └── adr-*.md
```

## Design Principles

- **Documentation-first**: ADRs before code
- **Measurement discipline**: Latency at every stage
- **Event-driven**: Tick-by-tick, no batching
- **Separation of concerns**: Trade FH, Quote FH, RDB, RTE
- **Single responsibility**: One process, one job
- **Ephemeral by design**: Focus on real-time behaviour

## Implementation Status

| Component | Status |
|-----------|--------|
| Trade Feed Handler | Complete |
| Quote Feed Handler | Complete |
| Tickerplant | Complete |
| RDB | Complete |
| RTE | Complete |
| Dashboards | Planned |

## Dependencies

- C++17 compiler
- CMake 3.16+
- Boost (Beast, Asio)
- OpenSSL
- RapidJSON
- kdb+ 4.x
- tmux (optional)

## License

Educational and exploratory purposes.

## Acknowledgements

Architecture patterns from [Building Real Time Event Driven KDB-X Systems](https://dataintellect.com/) by Data Intellect.