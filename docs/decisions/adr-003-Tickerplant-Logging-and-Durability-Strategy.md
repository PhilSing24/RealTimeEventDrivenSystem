# ADR-003: Tickerplant Logging and Durability Strategy

## Status
Accepted (Updated 2025-12-24)

## Date
2025-12-17 (Updated 2025-12-24)

## Context

In a canonical kdb real-time architecture, the tickerplant (TP) is responsible for:

- Sequencing inbound events
- Publishing updates to real-time databases (RDBs)
- Optionally providing a durability boundary via logging

This project ingests real-time Binance trade data through an external C++ feed handler and publishes it directly into a tickerplant via IPC (ADR-002).

A key design decision is whether the tickerplant should:
- Log incoming updates to disk (durable TP), or
- Operate purely in-memory (non-durable TP)

This decision affects recovery semantics, operational complexity, latency, and alignment with the project's exploratory goals.

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

The tickerplant implements **optional persistent logging**, disabled by default.

### Update (2025-12-24)

TP logging has been implemented to support:
- Performance testing via log replay
- Development and debugging workflows
- Future recovery capabilities

### Architecture

The tickerplant now supports both modes:
- **Logging disabled** (default): Pure distribution, no disk I/O
- **Logging enabled**: Writes to `logs/` directory with daily rotation

### Configuration

```q
.tp.cfg.logEnabled:1b;          / Enable/disable logging
.tp.cfg.logDir:"logs";          / Log directory
```

### Log Format

- One file per day: `logs/YYYY.MM.DD.log`
- Binary IPC format (serialized q objects)
- Each message: `(`.u.upd; tablename; rowdata)`
- Fixed message size: 145 bytes per trade

### Logging Implementation

```q
.tp.log:{[tbl;data]
  if[not .tp.cfg.logEnabled; :()];
  .tp.logHandle enlist (`.u.upd; tbl; data);
  };
```

Key characteristics:
- Async append (non-blocking)
- No compression
- Daily rotation via `.tp.rotate[]`

### End-of-Day Behaviour

- Log files rotate at midnight or on manual `.tp.rotate[]` call
- Old logs retained for replay/debugging
- No Historical Database (HDB) - logs are for replay, not query

### Downstream Recovery Implications

With logging enabled, downstream components can recover via replay:

| Component | On Restart | Recovery Method |
|-----------|------------|-----------------|
| TP | Restarts empty | N/A (stateless) |
| RDB | Starts empty | Replay from TP log |
| RTE | State lost | Replay from TP log |

Recovery via replay is now supported (see ADR-006).

### System-Wide Durability Stance

| Mode | Data Recovery |
|------|---------------|
| Logging disabled | No recovery; data lost on any failure |
| Logging enabled | Replay possible from log files |

### Performance Impact

Logging adds minimal overhead:
- Async file I/O (non-blocking)
- ~145 bytes per trade
- No measurable latency impact at current message rates

## Rationale

Logging was implemented because:

- Enables performance testing via replay (447K msg/s measured)
- Supports development and debugging workflows
- Provides foundation for future recovery capabilities
- Minimal complexity (optional, disabled by default)
- No significant latency impact

### Latency Considerations

With logging disabled:
- No disk I/O in critical path
- Lowest possible latency

With logging enabled:
- Async writes minimize impact
- Suitable for development/testing
- Production deployments can disable if latency-critical

## Alternatives Considered

### 1. No logging at all
Originally selected, later revised:
- Prevented replay-based testing
- Made debugging difficult
- Limited future recovery options

### 2. Synchronous logging
Rejected:
- Adds latency to critical path
- Blocks on disk I/O
- Not necessary for exploratory project

### 3. Separate Logger Process
Rejected:
- Adds architectural complexity
- Overkill for current scale
- May be reconsidered for production

## Consequences

### Positive

- Performance testing via replay now possible
- Debugging workflows improved
- Foundation for recovery laid
- Optional (no impact when disabled)
- Simple implementation

### Negative / Trade-offs

- Log files consume disk space
- Log format is binary (not human-readable)
- No automatic recovery (manual replay required)
- Fixed message size assumption (145 bytes)

## Implementation Details

### Log File Structure

```
logs/
└── 2025.12.24.log    # Binary IPC format
```

### Replay Tool

`replay.q` reads log files and sends to target RTE:

```bash
q kdb/replay.q -port 5012
.replay.run[]
```

Performance: 447K msg/s replay rate.

### Standalone Mode

RTE supports `-standalone` flag for replay testing without TP connection:

```bash
q kdb/rte.q -standalone
```

## Future Evolution

| Enhancement | Status |
|-------------|--------|
| TP logging | ✓ Implemented |
| Replay tooling | ✓ Implemented |
| Automatic RDB recovery | Planned |
| HDB for historical queries | Out of scope |
| Log compression | Out of scope |

## Links / References

- `../kdbx-real-time-architecture-reference.md`
- `adr-002-feed-handler-to-kdb-ingestion-path.md` (async IPC)
- `adr-006-recovery-and-replay-strategy.md` (replay capability)
- `kdb/tp.q` (logging implementation)
- `kdb/replay.q` (replay tool)
