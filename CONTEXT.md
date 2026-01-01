# CONTEXT.md - Project Status for Claude Sessions

*Last updated: 2025-12-29*

## Project Overview

Real-time Binance market data → C++ Feed Handlers → kdb+ pipeline (TP → RDB → RTE)

## Architecture
```
Binance WebSocket ──► Trade FH (C++) ──┬──► TP:5010 ──┬──► RDB:5011 (trade storage)
                                       │              │
Binance WebSocket ──► Quote FH (C++) ──┘              ├──► RTE:5012 (rolling analytics)
                                                      │
                                                      └──► Log files
                                                           ├── trade.log
                                                           └── quote.log

## Component Status

| File | Purpose | Status |
|------|---------|--------|
| `cpp/src/feed_handler.cpp` | Trade WebSocket client, JSON parse, IPC publish | ✓ Complete |
| `cpp/src/quote_handler_main.cpp` | Quote handler entry point | ✓ Complete |
| `cpp/include/quote_handler.hpp` | Depth WebSocket, snapshot reconciliation | ✓ Complete |
| `cpp/include/order_book.hpp` | OrderBook state machine, L1Publisher | ✓ Complete |
| `cpp/include/rest_client.hpp` | REST snapshot client | ✓ Complete |
| `kdb/tp.q` | Tickerplant with pub/sub and separate logging | ✓ Complete |
| `kdb/rdb.q` | Trade storage (subscribes to trade_binance only) | ✓ Complete |
| `kdb/rte.q` | Rolling analytics (5-min window) | ✓ Complete |
| `kdb/replay.q` | Log replay tool | ✓ Complete |

## Project Structure
```
binance_feed_handler/
├── cpp/
│   ├── include/
│   │   ├── order_book.hpp
│   │   ├── rest_client.hpp
│   │   └── quote_handler.hpp
│   ├── src/
│   │   ├── main.cpp
│   │   ├── feed_handler.cpp
│   │   ├── quote_handler_main.cpp
│   │   └── test_snapshot.cpp
│   └── third_party/kdb/
│       ├── k.h
│       └── c.o
├── kdb/
│   ├── tp.q
│   ├── rdb.q
│   ├── rte.q
│   └── replay.q
├── docs/
│   └── decisions/
│       ├── adr-001 to adr-008
│       └── adr-009-L1-Order-Book-Architecture.md
├── logs/
│   ├── YYYY.MM.DD.trade.log
│   └── YYYY.MM.DD.quote.log
├── CMakeLists.txt
├── start.sh
└── stop.sh
```

## Recent Changes

- **2025-12-29**: Added L1 Order Book (Quote Handler)
  - Separate process for depth stream ingestion
  - OrderBook state machine (INIT/SYNCING/VALID/INVALID)
  - REST snapshot + delta reconciliation per Binance spec
  - L1 publication on change or 50ms timeout
  - ADR-009 documents architecture
- **2025-12-29**: Separate log files
  - `trade.log` for trades
  - `quote.log` for quotes
  - Updated ADR-003
- **2025-12-29**: Project restructure
  - C++ code moved to `cpp/` directory
  - Headers in `cpp/include/`, sources in `cpp/src/`
- **2025-12-24**: Added TP logging and replay tool
  - TP writes binary logs to `logs/` (daily rotation)
  - `replay.q` replays at 447K msg/s
  - Standalone mode for RTE

## Tables

| Table | Fields | Location | Subscribers |
|-------|--------|----------|-------------|
| `trade_binance` | 14 fields | TP, RDB | RDB, RTE |
| `quote_binance` | 11 fields | TP | (none currently) |

## Open Issues / Next Steps

1. [ ] KX Dashboards visualization
2. [ ] RDB subscription to quotes (optional)
3. [ ] Quote telemetry aggregation
4. [ ] Production hardening (reconnect logic)
5. [ ] L5 publication (future)

## Key Technical Details

### Quote Handler State Machine
```
INIT → SYNCING → VALID ↔ INVALID
       (snapshot)  (deltas)  (gap)
```

### Log Files
- Trade log: `logs/YYYY.MM.DD.trade.log`
- Quote log: `logs/YYYY.MM.DD.quote.log`
- Binary IPC format, 145-byte messages (trades)

### Publication Discipline (Quotes)
- Publish on L1 change (price or qty)
- Publish on validity change
- Publish on 50ms timeout
- Never publish stale data as valid

## Performance Baselines

| Metric | Value |
|--------|-------|
| Replay throughput | 447K msg/s |
| Live trade rate | ~50-100 trades/sec |
| Live quote rate | ~20-50 quotes/sec (after filtering) |
| Log message size | 145 bytes (trades) |

## Useful Commands
```bash
# Build
cmake -S . -B build
cmake --build build

# Start full pipeline
./start.sh

# Stop all
./stop.sh

# Manual start
q kdb/tp.q                      # Terminal 1
q kdb/rdb.q                     # Terminal 2
q kdb/rte.q                     # Terminal 3
./build/binance_feed_handler    # Terminal 4
./build/binance_quote_handler   # Terminal 5

# Verify data
select count i by sym from trade_binance  # In TP or RDB
select count i by sym from quote_binance  # In TP only
rollAnalytics                              # In RTE
```

## Key Decisions Summary

| Decision | Choice | ADR |
|----------|--------|-----|
| C++ Standard | C++17 | - |
| Trade ingestion | Tick-by-tick, async IPC | ADR-002 |
| Quote ingestion | Snapshot + delta reconciliation | ADR-009 |
| Process architecture | Separate Trade FH and Quote FH | ADR-009 |
| Durability | TP logging (separate files) | ADR-003 |
| Recovery | Replay from TP log | ADR-006 |
| Analytics | Tick-by-tick, 5-min rolling window | ADR-004 |
| Telemetry | 1-sec buckets, 15-min retention | ADR-005 |

## Files to Upload at Session Start

1. This file (`CONTEXT.md`)
2. Any files being actively worked on
3. Relevant ADRs if discussing architecture
4. `CMakeLists.txt` if build issues