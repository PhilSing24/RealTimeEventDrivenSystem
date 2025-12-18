# ADR-008: Error Handling Strategy

## Status
Accepted

## Date
2025-12-18

## Context

The system consists of multiple components communicating via network:

```
Binance ──WebSocket──► FH ──IPC──► TP ──IPC──► RDB
                                       ──IPC──► RTE
```

Each component can experience failures:

| Component | Potential Failures |
|-----------|-------------------|
| Feed Handler | WebSocket disconnect, JSON parse error, IPC failure |
| Tickerplant | Subscriber disconnect, invalid message, publish failure |
| RDB | TP connection loss, timer error, query error |
| RTE | TP connection loss, computation error |

The project is explicitly exploratory (ADR-003, ADR-006):
- No durability requirements
- No recovery mechanisms
- Data loss is acceptable
- Focus is on understanding real-time behaviour

A decision is required on how errors are handled across the system.

## Notation

| Acronym | Definition |
|---------|------------|
| FH | Feed Handler |
| IPC | Inter-Process Communication |
| RDB | Real-Time Database |
| RTE | Real-Time Engine |
| TP | Tickerplant |

## Decision

The system adopts a **fail-fast with logging** error handling strategy appropriate for an exploratory project.

### Philosophy

| Principle | Rationale |
|-----------|-----------|
| Fail fast | Surface problems immediately; don't hide failures |
| Log clearly | Make failures visible and diagnosable |
| Don't retry silently | Retries can mask problems; prefer explicit restart |
| Accept data loss | Consistent with ADR-003 and ADR-006 |
| Keep it simple | Avoid complex retry/recovery logic |

### Error Categories

Errors are categorised by severity and response:

| Category | Examples | Response |
|----------|----------|----------|
| **Fatal** | Cannot connect to upstream, config error | Log and exit |
| **Connection** | Lost connection to peer | Log and attempt reconnect |
| **Transient** | Parse error, invalid message | Log and skip message |
| **Silent** | Expected disconnects | Handle gracefully |

### Per-Component Strategy

#### Feed Handler (C++)

| Error | Category | Handling |
|-------|----------|----------|
| Cannot connect to Binance | Fatal | Log, exit with error code |
| Cannot connect to TP | Fatal | Log, exit with error code |
| WebSocket disconnect (Binance) | Connection | Log, reconnect with backoff |
| TP connection lost | Connection | Log, reconnect with backoff |
| JSON parse error | Transient | Log warning, skip message |
| Missing required field | Transient | Log warning, skip message |
| IPC send failure | Transient | Log warning, continue |

**Reconnection backoff:**

| Attempt | Delay |
|---------|-------|
| 1 | 1 second |
| 2 | 2 seconds |
| 3 | 4 seconds |
| 4+ | 8 seconds (max) |

**Current implementation status:**
- Basic error handling exists
- Reconnection logic: minimal (needs enhancement)
- JSON errors: logged, message skipped

#### Tickerplant (q)

| Error | Category | Handling |
|-------|----------|----------|
| Invalid table name | Transient | Signal error to caller |
| Subscriber disconnect | Silent | Remove from `.u.w` via `.z.pc` |
| Publish to dead handle | Transient | Caught by `.z.pc`, handle removed |
| Malformed message | Transient | Let q signal error (logged) |

**Implementation:**
```q
/ Handle subscriber disconnect gracefully
.z.pc:{[h]
  .u.w:{x except h} each .u.w;
  -1 "Subscriber disconnected: handle ",string h;
  };
```

#### RDB (q)

| Error | Category | Handling |
|-------|----------|----------|
| Cannot connect to TP | Fatal | Log, exit |
| TP connection lost | Connection | Log, process continues (no auto-reconnect) |
| Timer callback error | Transient | Log, continue (next timer fires) |
| Telemetry computation error | Transient | Log, skip bucket |

**Implementation:**
```q
/ Protected TP connection
.rdb.connect:{[]
  h:@[hopen; `::5010; {-1 "Failed to connect to TP: ",x; 0N}];
  if[null h; '"Cannot connect to tickerplant"];
  ...
  };

/ Timer with error protection (recommended enhancement)
.z.ts:{@[.rdb.computeTelemetry; ::; {-1 "Telemetry error: ",x}]};
```

#### RTE (q)

| Error | Category | Handling |
|-------|----------|----------|
| Cannot connect to TP | Fatal | Log, exit |
| TP connection lost | Connection | Log, process continues |
| Unknown symbol | Silent | Initialize buffer automatically |
| Computation error | Transient | Log, analytics may be stale |

**Implementation:**
```q
/ Auto-initialize unknown symbols (not an error)
if[not s in key .rte.buffer; .rte.initBuffer[s]];
```

### Logging Strategy

**Log levels (conceptual):**

| Level | Usage | Example |
|-------|-------|---------|
| ERROR | Failures requiring attention | "Failed to connect to TP" |
| WARN | Recoverable issues | "JSON parse failed, skipping" |
| INFO | Normal operations | "Subscribed to trade_binance" |
| DEBUG | Diagnostic detail | "Processed trade: BTCUSDT 87000" |

**Current implementation:**
- kdb+: `-1` for stdout (info/error mixed)
- C++: `std::cout` / `std::cerr`

**Format (recommended):**
```
[LEVEL] [COMPONENT] [TIMESTAMP] Message
```

Example:
```
[ERROR] [FH] [2025-12-18T10:30:45Z] WebSocket disconnected from Binance
[INFO] [TP] [2025-12-18T10:30:46Z] Subscriber connected: handle 5
[WARN] [RDB] [2025-12-18T10:30:47Z] Telemetry bucket empty, skipping
```

### What Is NOT Handled

Consistent with the exploratory nature:

| Scenario | Status | Rationale |
|----------|--------|-----------|
| Automatic TP reconnect in RDB/RTE | Not implemented | Manual restart acceptable |
| Message replay after gap | Not implemented | ADR-006 |
| Persistent error logs | Not implemented | ADR-003 ephemeral stance |
| Alerting | Not implemented | Human observation via dashboard |
| Circuit breakers | Not implemented | Overkill for 2 symbols |
| Dead letter queues | Not implemented | Dropped messages acceptable |

### Error Visibility

Errors are made visible through:

| Method | Purpose |
|--------|---------|
| Console output | Immediate visibility during development |
| Dashboard staleness | `isValid`, `fillPct` indicate data quality |
| Gap detection | `fhSeqNo` gaps observable in RDB |
| Process exit | Fatal errors surface immediately |

### Startup Validation

Each component validates its environment at startup:

| Component | Validation |
|-----------|------------|
| FH | Can resolve Binance host, can connect to TP |
| TP | Port available, schema valid |
| RDB | Can connect to TP, subscription succeeds |
| RTE | Can connect to TP, subscription succeeds |

Failure during startup = immediate exit (fail fast).

## Rationale

This approach was selected because:

- **Simplicity**: Complex retry logic adds code and hides problems
- **Visibility**: Fail-fast surfaces issues immediately
- **Consistency**: Aligns with ADR-003 (ephemeral) and ADR-006 (no recovery)
- **Appropriate**: Error handling matches project maturity
- **Debuggable**: Clear logs aid understanding

## Alternatives Considered

### 1. Comprehensive retry with exponential backoff everywhere
Rejected:
- Adds complexity
- Can mask underlying problems
- Overkill for exploratory project

May be reconsidered for production deployment.

### 2. Structured logging framework (e.g., spdlog, log4q)
Rejected:
- Additional dependency
- Setup overhead
- Console output sufficient for single-user development

### 3. Health check endpoints
Rejected:
- Adds infrastructure complexity
- Dashboard provides sufficient visibility
- No external monitoring system to consume health checks

### 4. Automatic reconnection everywhere
Rejected:
- Complex state management (what about in-flight messages?)
- Manual restart is acceptable and explicit
- Keeps failure handling predictable

May be reconsidered for RDB/RTE TP reconnection.

### 5. Message validation layer
Rejected:
- Schema is controlled end-to-end
- FH and TP are trusted components
- Validation overhead not justified

## Consequences

### Positive

- Simple, understandable error handling
- Problems surface immediately (fail fast)
- Easy to diagnose issues via logs
- No hidden retry loops masking problems
- Consistent with ephemeral data stance
- Low implementation overhead

### Negative / Trade-offs

- Manual restart required for some failures
- No automatic recovery from TP disconnect (RDB/RTE)
- Transient errors cause data loss (by design)
- No persistent audit trail of errors
- Log format is informal (no structured logging)

These trade-offs are acceptable for the current phase.

## Implementation Checklist

### Implemented

- [x] FH: Exit on startup connection failure
- [x] FH: Skip malformed JSON messages
- [x] TP: `.z.pc` handles subscriber disconnect
- [x] TP: `.u.sub` validates table name
- [x] RDB: Protected TP connection with error message
- [x] RTE: Protected TP connection with error message
- [x] RTE: Auto-initialize unknown symbols

### Recommended Enhancements

- [ ] FH: Reconnect to Binance with backoff
- [ ] FH: Reconnect to TP with backoff
- [ ] FH: Log with consistent format and levels
- [ ] RDB: Protected timer callback
- [ ] RDB: Log telemetry errors
- [ ] All: Consistent log format across components

### Out of Scope

- [ ] Automatic RDB/RTE reconnect to TP
- [ ] Structured logging
- [ ] External log aggregation
- [ ] Alerting
- [ ] Health check endpoints

## Future Evolution

| Enhancement | Trigger |
|-------------|---------|
| Automatic reconnection | Frequent manual restarts become painful |
| Structured logging | Need for log analysis or aggregation |
| Health endpoints | External monitoring integration |
| Alerting | Production deployment |
| Circuit breakers | High message rates, cascading failures |

## Links / References

- `../kdbx-real-time-architecture-reference.md` (fail-fast principle)
- `adr-001-timestamps-and-latency-measurement.md` (fhSeqNo for gap detection)
- `adr-003-tickerplant-logging-and-durability-strategy.md` (ephemeral stance)
- `adr-004-real-time-rolling-analytics-computation.md` (validity indicators)
- `adr-006-recovery-and-replay-strategy.md` (no recovery)
- `adr-007-visualisation-and-consumption-strategy.md` (observability via dashboard)
