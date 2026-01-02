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
| RDB | 5011 | Real-Time Database - trade/quote storage, health metrics |
| RTE | 5012 | Real-Time Engine - rolling analytics |
| Trade FH | - | Trade feed handler - WebSocket to IPC |
| Quote FH | - | Quote feed handler - L1 book with snapshot reconciliation |

## What This Project Does

- Ingests **real-time trades** and **L1 quotes** from Binance
- Implements **snapshot + delta reconciliation** for order books
- Captures **latency measurements** at every pipeline stage
- Provides **automatic reconnection** with exponential backoff
- Supports **graceful shutdown** via signal handling
- Uses **JSON configuration files** for runtime settings
- Includes **structured logging** with spdlog
- Publishes **health metrics** every 5 seconds for monitoring

## Quick Start
```bash
# Build
cmake -S . -B build
cmake --build build

# Start pipeline (uses tmux)
./start.sh

# Or manually:
q kdb/tp.q      # Terminal 1
q kdb/rdb.q     # Terminal 2
q kdb/rte.q     # Terminal 3
./build/trade_feed_handler   # Terminal 4
./build/quote_feed_handler   # Terminal 5
```

## Verify It Works

```q
/ TP or RDB - check data flowing
select count i by sym from trade_binance
select count i by sym from quote_binance

/ RDB - health metrics
select last uptimeSec, last msgsReceived, last connState by handler from health_feed_handler

/ RTE - rolling analytics (isValid flips to 1b after ~2.5 min)
rollAnalytics
```

## Configuration

Edit `config/trade_feed_handler.json` or `config/quote_feed_handler.json`:
```json
{
    "symbols": ["btcusdt", "ethusdt", "solusdt"],
    "tickerplant": {"host": "localhost", "port": 5010},
    "reconnect": {"initial_backoff_ms": 1000, "max_backoff_ms": 8000},
    "logging": {"level": "info", "file": ""}
}
```

Custom config path: `./build/trade_feed_handler /path/to/config.json`

## Tables

### trade_binance (14 fields)
Core fields: `time`, `sym`, `tradeId`, `price`, `qty`, `buyerIsMaker`
Latency fields: `fhRecvTimeUtcNs`, `fhParseUs`, `fhSendUs`, `fhSeqNo`, `tpRecvTimeUtcNs`, `rdbApplyTimeUtcNs`

### quote_binance (12 fields)
Core fields: `time`, `sym`, `bidPrice`, `bidQty`, `askPrice`, `askQty`, `isValid`
Latency fields: `fhRecvTimeUtcNs`, `fhSeqNo`, `tpRecvTimeUtcNs`, `rdbApplyTimeUtcNs`

### health_feed_handler (10 fields)
`time`, `handler`, `startTimeUtc`, `uptimeSec`, `msgsReceived`, `msgsPublished`, `lastMsgTimeUtc`, `lastPubTimeUtc`, `connState`, `symbolCount`

## Feed Handler Features

- **Automatic reconnection** with exponential backoff (Binance and TP)
- **Graceful shutdown** on SIGINT/SIGTERM
- **JSON configuration** for symbols, ports, logging
- **Structured logging** via spdlog (info/debug levels)
- **Health metrics** published every 5 seconds
- **Trade ID validation** for gap/duplicate detection
- **Sequence validation** for order book integrity

## Project Structure
```
.
├── cpp/
│   ├── src/                    # Feed handler implementations
│   └── include/                # Headers (order_book, rest_client, config, logger)
├── kdb/
│   ├── tp.q                    # Tickerplant
│   ├── rdb.q                   # RDB
│   └── rte.q                   # RTE
├── config/
│   ├── trade_feed_handler.json
│   └── quote_feed_handler.json
├── logs/                       # TP binary logs
├── docs/                       # ADRs and references
├── start.sh / stop.sh
└── CMakeLists.txt
```

## Dependencies

- C++17, CMake 3.16+, Boost (Beast/Asio), OpenSSL, RapidJSON, spdlog, kdb+ 4.x

## Acknowledgements

Architecture patterns from [Building Real Time Event Driven KDB-X Systems](https://dataintellect.com/) by Data Intellect.
