# CONTEXT.md - Project Status for Claude Sessions

*Last updated: 2026-01-02*

## Project Overview

Real-time Binance market data → C++ Feed Handlers → kdb+ pipeline (TP → RDB → RTE)

## Architecture
```
Binance WebSocket ──► Trade FH (C++) ──┬──► TP:5010 ──┬──► RDB:5011 (storage + health)
                                       │              │
Binance WebSocket ──► Quote FH (C++) ──┘              └──► RTE:5012 (rolling analytics)
                                                      
Log files: logs/*.trade.log, logs/*.quote.log
```

## Component Status

| File | Purpose | Status |
|------|---------|--------|
| `cpp/src/trade_feed_handler.cpp` | Trade WebSocket, JSON parse, IPC publish | ✓ Complete |
| `cpp/src/quote_feed_handler.cpp` | Quote handler with snapshot reconciliation | ✓ Complete |
| `cpp/include/trade_feed_handler.hpp` | Trade handler class definition | ✓ Complete |
| `cpp/include/quote_feed_handler.hpp` | Quote handler class definition | ✓ Complete |
| `cpp/include/order_book.hpp` | OrderBook state machine, L1Publisher | ✓ Complete |
| `cpp/include/rest_client.hpp` | REST snapshot client | ✓ Complete |
| `cpp/include/config.hpp` | JSON config loader | ✓ Complete |
| `cpp/include/logger.hpp` | spdlog wrapper | ✓ Complete |
| `kdb/tp.q` | Tickerplant with pub/sub and logging | ✓ Complete |
| `kdb/rdb.q` | Storage for trades, quotes, health | ✓ Complete |
| `kdb/rte.q` | Rolling analytics (5-min window) | ✓ Complete |
| `kdb/replay.q` | Log replay tool | ✓ Complete |

## Project Structure
```
binance_feed_handler/
├── cpp/
│   ├── include/
│   │   ├── trade_feed_handler.hpp
│   │   ├── quote_feed_handler.hpp
│   │   ├── order_book.hpp
│   │   ├── rest_client.hpp
│   │   ├── config.hpp
│   │   └── logger.hpp
│   ├── src/
│   │   ├── trade_feed_handler.cpp
│   │   └── quote_feed_handler.cpp
│   └── third_party/kdb/
│       ├── k.h
│       └── c.o
├── config/
│   ├── trade_feed_handler.json
│   └── quote_feed_handler.json
├── kdb/
│   ├── tp.q
│   ├── rdb.q
│   ├── rte.q
│   └── replay.q
├── docs/decisions/
│   └── adr-001 to adr-009
├── logs/
├── CMakeLists.txt
├── start.sh
└── stop.sh
```

## Recent Changes

- **2026-01-02**: Production hardening complete
  - JSON configuration files (`config/*.json`)
  - Structured logging via spdlog
  - Health metrics published every 5 seconds
  - `health_feed_handler` table in TP/RDB
  - Automatic reconnection with exponential backoff
  - Graceful shutdown on SIGINT/SIGTERM
  - Class-based architecture for feed handlers

- **2025-12-29**: Added L1 Order Book (Quote Handler)
  - Separate process for depth stream ingestion
  - OrderBook state machine (INIT/SYNCING/VALID/INVALID)
  - REST snapshot + delta reconciliation
  - L1 publication on change or 50ms timeout

- **2025-12-24**: Added TP logging and replay tool

## Tables

| Table | Fields | Location |
|-------|--------|----------|
| `trade_binance` | 14 fields | TP, RDB |
| `quote_binance` | 12 fields | TP, RDB |
| `health_feed_handler` | 10 fields | TP, RDB |

## Feed Handler Features

- **Reconnection**: Exponential backoff (1s → 8s max) for Binance and TP
- **Signal handling**: Graceful shutdown on SIGINT/SIGTERM
- **Configuration**: JSON files for symbols, ports, logging
- **Logging**: spdlog with levels (info/debug), console + optional file
- **Health**: Uptime, message counts, connection state every 5 seconds
- **Validation**: Trade ID gaps, order book sequence numbers

## Configuration Example
```json
{
    "symbols": ["btcusdt", "ethusdt", "solusdt"],
    "tickerplant": {"host": "localhost", "port": 5010},
    "reconnect": {"initial_backoff_ms": 1000, "max_backoff_ms": 8000},
    "logging": {"level": "info", "file": ""}
}
```

## Useful Commands
```bash
# Build
cmake -S . -B build && cmake --build build

# Start pipeline
./start.sh

# Manual start
q kdb/tp.q                       # Terminal 1
q kdb/rdb.q                      # Terminal 2  
q kdb/rte.q                      # Terminal 3
./build/trade_feed_handler       # Terminal 4
./build/quote_feed_handler       # Terminal 5

# Custom config
./build/trade_feed_handler /path/to/config.json

# Verify
select count i by sym from trade_binance
select count i by sym from quote_binance
select last uptimeSec, last connState by handler from health_feed_handler
rollAnalytics
```

## Key Decisions Summary

| Decision | Choice | ADR |
|----------|--------|-----|
| Trade ingestion | Tick-by-tick, async IPC | ADR-002 |
| Quote ingestion | Snapshot + delta reconciliation | ADR-009 |
| Durability | TP logging (separate files) | ADR-003 |
| Analytics | 5-min rolling window | ADR-004 |
| Telemetry | 1-sec buckets, 15-min retention | ADR-005 |
| Error handling | Fail-fast with logging | ADR-008 |

## Open Items

1. [ ] KX Dashboards visualization
2. [ ] Quote telemetry aggregation
3. [ ] L5 order book (future)
