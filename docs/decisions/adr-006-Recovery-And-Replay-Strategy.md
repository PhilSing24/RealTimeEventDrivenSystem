# ADR-006: Recovery and Replay Strategy

## Status
Accepted (Updated 2025-12-29)

## Date
2025-12-17 (Updated 2025-12-29)

## Context

In a typical production-grade KDB-X architecture, recovery and replay are achieved via:
- Durable tickerplant logs
- Replay of persisted data on restart
- Deterministic rebuild of downstream state (RDB, RTE)

The reference architecture describes multiple recovery patterns:

| Pattern | Description |
|---------|-------------|
| Recovery via TP log | Replay persisted log to rebuild RDB/RTE state |
| Recovery via RDB query | Component queries RDB for recent data |
| Recovery via on-disk cache | Load snapshot, replay delta |
| Upstream replay | Source provides missed data on reconnect |

This project is explicitly **exploratory and incremental** in nature.

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

The project implements a **tiered recovery model** with replay capability for testing and development.

### Recovery Capability Summary

| Level | Capability | Status |
|-------|------------|--------|
| TP log replay | Replay log file to rebuild state | ✓ Implemented |
| RDB recovery | Rebuild RDB from TP log | Planned |
| RTE recovery from replay | Replay log to rebuild analytics | ✓ Implemented |
| FH recovery from Binance | Replay missed data from exchange | ✗ Not available |
| Gap detection | Identify missed events via sequence numbers | ✓ Available |
| Gap recovery | Fill gaps with missed data | ✗ Not implemented |

### Log Format

- Binary IPC format (serialized q objects)
- Separate files per data type (see ADR-003):
  - `logs/YYYY.MM.DD.trade.log` — Trade events
  - `logs/YYYY.MM.DD.quote.log` — Quote events
- Daily rotation at midnight

### Replay Tool

`replay.q` provides log replay capability for specific data types:

```bash
# Start RTE in standalone mode
q kdb/rte.q -standalone

# Replay trades to RTE
q kdb/replay.q -logfile logs/2025.12.29.trade.log -port 5012

# Replay quotes (when consumer exists)
q kdb/replay.q -logfile logs/2025.12.29.quote.log -port 5011
```

**Performance:** ~450K msg/s replay rate (varies by message size).

### Standalone Mode

RTE supports `-standalone` flag to skip TP connection:

```q
.rte.cfg.standalone:0b;  / Default: connect to TP
args:.Q.opt .z.x;
if[`standalone in key args; .rte.cfg.standalone:1b];
```

Usage:
```bash
q kdb/rte.q -standalone    # No TP connection
q kdb/rte.q                # Normal mode (connects to TP)
```

### Failure Scenario Matrix

| Failure | Data Impact | Recovery Action | Gap |
|---------|-------------|-----------------|-----|
| FH disconnects from Binance | Events during disconnect lost | FH reconnects; resumes live stream | Permanent |
| FH disconnects from TP | Events during disconnect lost | FH reconnects to TP; resumes publishing | Permanent |
| FH crash | Events during downtime lost | Restart FH; reconnect to Binance | Permanent |
| TP crash | RDB/RTE lose subscription | Restart TP; subscribers reconnect | Recoverable via log |
| RDB crash | All in-memory data lost | Restart RDB; replay from trade log | Recoverable |
| RTE crash | Analytics state lost | Restart RTE; replay from trade log | Recoverable |
| Full system restart | Everything lost | Replay TP logs to rebuild state | Recoverable |

### Gap Detection vs Gap Recovery

ADR-001 defines `fhSeqNo` (feed handler sequence number) and `tradeId` (Binance trade ID) for correlation.

| Capability | Status | Mechanism |
|------------|--------|-----------|
| Gap detection | ✓ Available | `fhSeqNo` gaps indicate missed FH events |
| Gap attribution | ✓ Available | Distinguish FH gaps from Binance gaps |
| Gap reporting | ✓ Available | Observable via telemetry (ADR-005) |
| Gap recovery | ✗ Not implemented | Gaps from FH downtime are permanent |

### Impact on Downstream Consumers

With replay capability:
- RTE can rebuild state from trade log
- Replay uses historical timestamps for correct windowing
- Analytics validity indicators (ADR-004) apply during replay
- Separate log files allow selective replay (trades only, quotes only)

### Data Loss Acceptance

| Scenario | Data Lost | Recovery |
|----------|-----------|----------|
| Network blip (FH ↔ Binance) | Seconds of events | Not recoverable |
| Component restart | In-memory state | Recoverable via TP log replay |
| Full system restart | All state | Recoverable via TP log replay |
| Log file deleted | Historical data | Not recoverable |

## Rationale

Replay was implemented because:

- Enables performance testing (~450K msg/s measured)
- Supports development and debugging workflows
- Provides foundation for production recovery
- Minimal complexity with optional logging
- Separate log files allow targeted replay per data type

## Alternatives Considered

### 1. No replay capability
Originally selected, later revised:
- Prevented performance testing
- Made debugging difficult
- Required live market for all testing

### 2. Use Binance REST API for gap fill
Rejected:
- Adds significant complexity
- REST and WebSocket data may differ
- Out of scope for current phase

### 3. Full checkpoint/snapshot recovery
Rejected:
- Significant implementation effort
- Replay from log is simpler
- Overkill for exploratory project

### 4. Single combined log file
Rejected (see ADR-003):
- Must replay everything to recover anything
- Mixed data types complicate debugging
- Can't replay trades without quotes

## Consequences

### Positive

- Performance testing now possible
- Development workflow improved
- State recoverable from logs
- Foundation for production recovery
- Standalone mode simplifies testing
- Selective replay per data type

### Negative / Trade-offs

- Log files require disk space
- Replay doesn't recover gaps from FH downtime
- Manual replay (not automatic on restart)
- Two log files to manage per day

## Implementation Checklist

### Implemented

- [x] TP logging to binary files
- [x] Separate log files per data type
- [x] Daily log rotation
- [x] replay.q tool
- [x] RTE standalone mode
- [x] High-speed replay

### Planned

- [ ] Automatic RDB recovery from log
- [ ] Automatic RTE recovery from log
- [ ] Log retention policy

### Out of Scope

- [ ] Binance REST API gap fill
- [ ] Real-time gap detection alerting
- [ ] Distributed recovery coordination

## Future Evolution

| Enhancement | Trigger |
|-------------|---------|
| Automatic recovery on startup | Production deployment |
| Log compression | Disk space concerns |
| Gap fill via REST | Gap recovery requirement |
| Distributed replay | Multi-process coordination |

## Links / References

- `../kdbx-real-time-architecture-reference.md`
- `adr-001-timestamps-and-latency-measurement.md` (sequence numbers)
- `adr-003-tickerplant-logging-and-durability-strategy.md` (TP logging, separate files)
- `adr-004-real-time-rolling-analytics-computation.md` (validity indicators)
- `adr-009-l1-order-book-architecture.md` (quote data source)
- `kdb/tp.q` (logging implementation)
- `kdb/replay.q` (replay tool)
- `kdb/rte.q` (standalone mode)

