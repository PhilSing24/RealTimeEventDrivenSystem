# Real-Time Event-Driven Market Data System

A real-time, event-driven market data pipeline built with **C++** and **kdb+/KDB-X**, inspired by production architectures used in tier-1 financial institutions.

## What This Project Does

```
Binance WebSocket ──► C++ Feed Handler ──► Tickerplant ──► RDB
                                                │
                                                └──► (RTE - future)
```

- Ingests **real-time trade data** from Binance (BTCUSDT, ETHUSDT)
- Captures **latency measurements** at every pipeline stage
- Publishes via **IPC** to a kdb+ tickerplant with pub/sub
- Stores trades with **full instrumentation** (14 timestamp/latency fields)
- Aggregates **telemetry metrics** (p50/p95/p99 latencies, throughput) every second

## Quick Start

```bash
# Terminal 1: Start Tickerplant
q kdb/tp.q

# Terminal 2: Start RDB
q kdb/rdb.q

# Terminal 3: Build and run Feed Handler
cmake -S . -B build
cmake --build build
./build/binance_feed_handler
```

## Verify It Works

In the RDB terminal (Terminal 2):

```q
/ Check data is flowing (both symbols)
select count i by sym from trade_binance

/ View recent trades with latencies
select sym, tradeId, fhParseUs, fhSendUs, 
    fhToTpMs:(tpRecvTimeUtcNs - fhRecvTimeUtcNs) % 1e6,
    tpToRdbMs:(rdbApplyTimeUtcNs - tpRecvTimeUtcNs) % 1e6
    from -5#trade_binance

/ View telemetry by symbol (after a few seconds)
select from telemetry_latency_e2e
```

## Configuration

### Adding/Removing Symbols

Edit the `SYMBOLS` vector in `src/feed_handler.cpp`:

```cpp
const std::vector<std::string> SYMBOLS = {
    "btcusdt",
    "ethusdt"
    // Add more symbols here (lowercase)
};
```

Rebuild and restart the feed handler. No changes needed to TP or RDB.

## Architecture

| Component | Port | Description |
|-----------|------|-------------|
| Feed Handler | — | C++ process: WebSocket → JSON parse → IPC publish |
| Tickerplant | 5010 | Receives trades, timestamps, publishes to subscribers |
| RDB | 5011 | Stores trades, computes telemetry aggregations |

### Latency Measurement Points

| Field | Source | Description |
|-------|--------|-------------|
| `fhRecvTimeUtcNs` | FH | Wall-clock when WebSocket message received |
| `fhParseUs` | FH | Parse/normalise duration (monotonic) |
| `fhSendUs` | FH | IPC send prep duration (monotonic) |
| `tpRecvTimeUtcNs` | TP | Wall-clock when TP receives message |
| `rdbApplyTimeUtcNs` | RDB | Wall-clock when trade is query-consistent |

### Telemetry Tables

| Table | Contents |
|-------|----------|
| `telemetry_latency_fh` | FH segment latencies (p50/p95/p99/max) by symbol |
| `telemetry_latency_e2e` | Cross-process latencies (FH→TP→RDB) by symbol |
| `telemetry_throughput` | Trade counts and volumes by symbol |

## Project Structure

```
.
├── CMakeLists.txt
├── src/
│   ├── main.cpp
│   └── feed_handler.cpp          # C++ WebSocket client + IPC publisher
├── kdb/
│   ├── tp.q                      # Tickerplant with pub/sub
│   └── rdb.q                     # RDB with telemetry aggregation
├── third_party/
│   └── kdb/
│       ├── k.h                   # kdb+ C API header
│       └── c.o                   # kdb+ C API library
└── docs/
    ├── README.md
    ├── kdbx-real-time-architecture-reference.md
    ├── kdbx-real-time-architecture-measurement-notes.md
    ├── api-binance.md
    ├── specs/
    │   └── trades-schema.md      # Canonical schema definition
    └── decisions/
        ├── adr-001-timestamps-and-latency-measurement.md
        ├── adr-002-feed-handler-to-kdb-ingestion-path.md
        ├── adr-003-tickerplant-logging-and-durability-strategy.md
        ├── adr-004-real-time-rolling-analytics-computation.md
        ├── adr-005-telemetry-and-metrics-aggregation-strategy.md
        ├── adr-006-recovery-and-replay-strategy.md
        └── adr-007-visualisation-and-consumption-strategy.md
```

## Design Principles

- **Documentation-first**: Architecture decisions documented before code
- **Measurement discipline**: Latency captured at every stage with explicit trust model
- **Event-driven**: Tick-by-tick processing, no batching
- **Separation of concerns**: FH (ingestion) → TP (distribution) → RDB (storage/analytics)
- **Ephemeral by design**: No persistence; focus on real-time behaviour

## Implementation Status

| Component | Status | Notes |
|-----------|--------|-------|
| Feed Handler | ✓ Complete | Multi-symbol, config-driven, full instrumentation |
| Tickerplant | ✓ Complete | Pub/sub, timestamp capture, subscriber management |
| RDB | ✓ Complete | Subscription, timestamp capture, telemetry aggregation |
| RTE | Planned | Rolling analytics (avgPrice, tradeCount) |
| Dashboards | Planned | KX Dashboards visualisation |

## Dependencies

- **C++17** compiler (GCC/Clang)
- **CMake** 3.16+
- **Boost** (Beast, Asio)
- **OpenSSL**
- **RapidJSON**
- **kdb+** 4.x (with valid license)

## Documentation

| Document | Purpose |
|----------|---------|
| [Architecture Reference](docs/kdbx-real-time-architecture-reference.md) | Design patterns for real-time KDB-X systems |
| [Measurement Notes](docs/kdbx-real-time-architecture-measurement-notes.md) | Latency measurement definitions and trust model |
| [Trades Schema](docs/specs/trades-schema.md) | Canonical schema with all 14 fields |
| [ADRs](docs/decisions/) | Architecture Decision Records |

## Typical Latencies (Single Host)

| Segment | Typical p99 |
|---------|-------------|
| FH parse | 10-50 µs |
| FH send | 1-10 µs |
| FH → TP | 0.1-0.5 ms |
| TP → RDB | 0.01-0.1 ms |
| **End-to-end** | **< 1 ms** |

## License

This project is for educational and exploratory purposes.

## Acknowledgements

Architecture patterns derived from [Building Real Time Event Driven KDB-X Systems](https://dataintellect.com/) by Data Intellect.
