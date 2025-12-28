# ADR-006: Recovery and Replay Strategy

## Status
Accepted (Updated 2025-12-24)

## Date
2025-12-17 (Updated 2025-12-24)

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

### Update (2025-12-24)

TP logging and replay tooling have been implemented:
- TP writes binary logs to `logs/` directory
- `replay.q` tool replays logs to RTE at high speed
- Standalone mode allows RTE testing without live TP

### Recovery Capability Summary

| Level | Capability | Status |
|-------|------------|--------|
| TP log replay | Replay log file to rebuild state | ✓ Implemented |
| RDB recovery | Rebuild RDB from TP log | Planned |
| RTE recovery from replay | Replay log to rebuild analytics | ✓ Implemented |
| FH recovery from Binance | Replay missed data from exchange | ✗ Not available |
| Gap detection | Identify missed events via sequence numbers | ✓ Available |
| Gap recovery | Fill gaps with missed data | ✗ Not implemented |

### Replay Tool

`replay.q` provides log replay capability:

```bash
# Start RTE in standalone mode
q kdb/rte.q -standalone

# Replay log to RTE
q kdb/replay.q -port 5012
.replay.run[]
```

**Performance:** 447K msg/s replay rate.

### Log Format

- Binary IPC format (serialized q objects)
- Fixed 145-byte messages
- Daily rotation: `logs/YYYY.MM.DD.log`

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
| FH disconnects from Binance | Trades during disconnect lost | FH reconnects; resumes live stream | Permanent |
| FH disconnects from TP | Trades during disconnect lost | FH reconnects to TP; resumes publishing | Permanent |
| FH crash | Trades during downtime lost | Restart FH; reconnect to Binance | Permanent |
| TP crash | RDB/RTE lose subscription | Restart TP; subscribers reconnect | Recoverable via log |
| RDB crash | All in-memory trades lost | Restart RDB; replay from TP log | Recoverable |
| RTE crash | Analytics state lost | Restart RTE; replay from TP log | Recoverable |
| Full system restart | Everything lost | Replay TP log to rebuild state | Recoverable |

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
- RTE can rebuild state from TP log
- Replay uses historical timestamps for correct windowing
- Analytics validity indicators (ADR-004) apply during replay

### Data Loss Acceptance

| Scenario | Data Lost | Recovery |
|----------|-----------|----------|
| Network blip (FH ↔ Binance) | Seconds of trades | Not recoverable |
| Component restart | In-memory state | Recoverable via TP log replay |
| Full system restart | All state | Recoverable via TP log replay |
| Log file deleted | Historical data | Not recoverable |

## Rationale

Replay was implemented because:

- Enables performance testing (measured 447K msg/s)
- Supports development and debugging workflows
- Provides foundation for production recovery
- Minimal complexity with optional logging

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

## Consequences

### Positive

- Performance testing now possible
- Development workflow improved
- State recoverable from logs
- Foundation for production recovery
- Standalone mode simplifies testing

### Negative / Trade-offs

- Log files require disk space
- Replay doesn't recover gaps from FH downtime
- Manual replay (not automatic on restart)
- Fixed message size assumption

## Implementation Checklist

### Implemented

- [x] TP logging to binary files
- [x] Daily log rotation
- [x] replay.q tool
- [x] RTE standalone mode
- [x] High-speed replay (447K msg/s)

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
- `adr-003-tickerplant-logging-and-durability-strategy.md` (TP logging)
- `adr-004-real-time-rolling-analytics-computation.md` (validity indicators)
- `kdb/tp.q` (logging implementation)
- `kdb/replay.q` (replay tool)
- `kdb/rte.q` (standalone mode)
