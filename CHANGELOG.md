# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2025-12-18

Initial release of the real-time event-driven market data system.

### Added

#### Feed Handler (C++)
- WebSocket connection to Binance using Boost.Beast/Asio
- TLS support via OpenSSL
- JSON parsing with RapidJSON
- Multi-symbol support (BTCUSDT, ETHUSDT) via combined stream
- Full instrumentation per ADR-001:
  - Wall-clock timestamp (`fhRecvTimeUtcNs`)
  - Monotonic durations (`fhParseUs`, `fhSendUs`)
  - Sequence number (`fhSeqNo`) for gap detection
- Async IPC to Tickerplant via kdb+ C API
- Tick-by-tick publishing (no batching)

#### Tickerplant (kdb+)
- Pub/sub infrastructure (`.u.sub`, `.u.pub`)
- Subscriber management (`.u.w` registry)
- Graceful disconnect handling (`.z.pc`)
- TP receive timestamp capture (`tpRecvTimeUtcNs`)
- Fan-out to multiple subscribers (RDB, RTE)

#### Real-Time Database (kdb+)
- Trade storage with 14-field schema
- RDB apply timestamp (`rdbApplyTimeUtcNs`)
- Telemetry aggregation (1-second buckets):
  - FH latency percentiles (p50/p95/p99)
  - E2E latency percentiles
  - Throughput metrics per symbol
- 15-minute telemetry retention with automatic cleanup
- Query interface for dashboards (port 5011)

#### Real-Time Engine (kdb+)
- Rolling analytics (5-minute window)
- Per-symbol state management
- Tick-by-tick processing
- Lazy eviction of stale entries
- Analytics output:
  - `lastPrice`, `avgPrice5m`, `tradeCount5m`
  - Validity tracking (`isValid`, `fillPct`)
- Query interface for dashboards (port 5012)

#### Visualization
- KX Dashboards integration
- Polling-based queries (1-second intervals)
- Market data display (prices, analytics)
- Latency monitoring panels
- Validity indicators

#### Infrastructure
- `start.sh` - tmux-based pipeline launcher
- `stop.sh` - clean shutdown script
- CMake build system

#### Documentation
- 8 Architecture Decision Records (ADRs):
  - ADR-001: Timestamps and Latency Measurement
  - ADR-002: Feed Handler to kdb Ingestion Path
  - ADR-003: Tickerplant Logging and Durability Strategy
  - ADR-004: Real-Time Rolling Analytics Computation
  - ADR-005: Telemetry and Metrics Aggregation Strategy
  - ADR-006: Recovery and Replay Strategy
  - ADR-007: Visualisation and Consumption Strategy
  - ADR-008: Error Handling Strategy
- Architecture reference (from Data Intellect paper)
- Measurement notes (latency definitions, clock trust model)
- Binance API specification
- Canonical trades schema (v2.0)
- Comprehensive code comments (FH, TP, RDB, RTE)

### Design Decisions

- **Ephemeral data**: No TP logging, no HDB (ADR-003)
- **No recovery**: Data loss accepted; focus on real-time behaviour (ADR-006)
- **Tick-by-tick**: Lowest latency, clearest measurement (ADR-002, ADR-004)
- **Fail-fast**: Simple error handling with logging (ADR-008)
- **Polling dashboards**: 1-second refresh via KX Dashboards (ADR-007)

### Known Limitations

- No automatic reconnection (FH to Binance, RDB/RTE to TP)
- No persistent storage (all data lost on restart)
- No gap recovery (gaps are detected but not filled)
- Manual process management (no supervisor/systemd)
- Single-host deployment only

---

## Future Considerations

Not implemented; captured for potential future phases:

| Feature | Relevant ADR |
|---------|--------------|
| TP logging and replay | ADR-003 |
| Historical Database (HDB) | ADR-003 |
| Automatic reconnection | ADR-008 |
| Gap recovery via REST API | ADR-006 |
| Streaming dashboards | ADR-007 |
| Multi-host deployment | - |
| Alerting integration | ADR-005, ADR-008 |
