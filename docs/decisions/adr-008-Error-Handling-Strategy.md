# ADR-008: Error Handling Strategy

## Status
Accepted (Updated 2025-12-29)

## Date
2025-12-18 (Updated 2025-12-29)

## Context

The system consists of multiple components communicating via network:

```
Binance Trade Stream ──WebSocket──► Trade FH ──┬──IPC──► TP ──IPC──► RDB
                                               │              ──IPC──► RTE
Binance Depth Stream ──WebSocket──► Quote FH ──┘
         ▲
         └──REST── (snapshot)
```

Each component can experience failures:

| Component | Potential Failures |
|-----------|-------------------|
| Trade FH | WebSocket disconnect, JSON parse error, IPC failure |
| Quote FH | WebSocket disconnect, REST failure, sequence gap, IPC failure |
| Tickerplant | Subscriber disconnect, invalid message, publish failure |
| RDB | TP connection loss, timer error, query error |
| RTE | TP connection loss, computation error |

The project is explicitly exploratory (ADR-003, ADR-006):
- TP logging provides durability
- Manual replay provides recovery
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
| Independent restart | Each process can be restarted without affecting others |
| Keep it simple | Avoid complex retry/recovery logic |

### Restart vs Reconnection

These are distinct concepts:

| Concept | Meaning | Status |
|---------|---------|--------|
| **Independent restart** | Can restart one process without restarting others | ✓ Supported |
| **Auto-reconnection** | Process automatically reconnects after connection loss | Minimal |

Independent restart is a benefit of the separate-process architecture (ADR-002). Auto-reconnection is a separate feature that requires additional implementation.

### Error Categories

Errors are categorised by severity and response:

| Category | Examples | Response |
|----------|----------|----------|
| **Fatal** | Cannot connect to upstream, config error | Log and exit |
| **Connection** | Lost connection to peer | Log and attempt reconnect |
| **Transient** | Parse error, invalid message | Log and skip message |
| **Recoverable** | Sequence gap, book invalid | Log, enter recovery state |
| **Silent** | Expected disconnects | Handle gracefully |

### Per-Component Strategy

#### Trade Feed Handler (C++)

| Error | Category | Handling |
|-------|----------|----------|
| Cannot connect to Binance | Fatal | Log, exit with error code |
| Cannot connect to TP | Fatal | Log, exit with error code |
| WebSocket disconnect (Binance) | Connection | Log, reconnect with backoff |
| TP connection lost | Connection | Log, reconnect with backoff |
| JSON parse error | Transient | Log warning, skip message |
| Missing required field | Transient | Log warning, skip message |
| IPC send failure | Transient | Log warning, continue |

#### Quote Feed Handler (C++)

| Error | Category | Handling |
|-------|----------|----------|
| Cannot connect to Binance | Fatal | Log, exit with error code |
| Cannot connect to TP | Fatal | Log, exit with error code |
| WebSocket disconnect (Binance) | Connection | Log, reconnect, re-sync book |
| TP connection lost | Connection | Log, reconnect with backoff |
| REST snapshot failure | Recoverable | Log, retry with backoff |
| Sequence gap detected | Recoverable | Log, transition to INVALID, re-sync |
| Book in INVALID state | Recoverable | Publish invalid quote, attempt re-sync |
| JSON parse error | Transient | Log warning, skip message |
| IPC send failure | Transient | Log warning, continue |

**Quote handler state transitions on error:**

```
VALID ──sequence gap──► INVALID ──re-sync──► SYNCING ──► VALID
                            │
                            └──publish invalid quote (once)
```

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
- Quote handler: sequence validation and state machine implemented

#### Tickerplant (q)

| Error | Category | Handling |
|-------|----------|----------|
| Invalid table name | Transient | Signal error to caller |
| Subscriber disconnect | Silent | Remove from `.u.w` via `.z.pc` |
| Publish to dead handle | Transient | Caught by `.z.pc`, handle removed |
| Malformed message | Transient | Let q signal error (logged) |
| Log write failure | Transient | Log error, continue publishing |

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

/ Timer with error protection
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
[ERROR] [TRADE_FH] [2025-12-29T10:30:45Z] WebSocket disconnected from Binance
[WARN] [QUOTE_FH] [2025-12-29T10:30:46Z] Sequence gap detected, BTCUSDT transitioning to INVALID
[INFO] [TP] [2025-12-29T10:30:47Z] Subscriber connected: handle 5
[INFO] [QUOTE_FH] [2025-12-29T10:30:48Z] BTCUSDT transitioning to VALID
```

### What Is NOT Handled

Consistent with the exploratory nature:

| Scenario | Status | Rationale |
|----------|--------|-----------|
| Automatic TP reconnect in RDB/RTE | Not implemented | Manual restart acceptable |
| Automatic recovery on startup | Not implemented | Manual replay via `replay.q` |
| Persistent error logs | Not implemented | Console output sufficient |
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
| Quote validity | `isValid` in `quote_binance` indicates book state |
| Process exit | Fatal errors surface immediately |

### Startup Validation

Each component validates its environment at startup:

| Component | Validation |
|-----------|------------|
| Trade FH | Can resolve Binance host, can connect to TP |
| Quote FH | Can resolve Binance host, can connect to TP, REST endpoint reachable |
| TP | Port available, schema valid, log directory writable |
| RDB | Can connect to TP, subscription succeeds |
| RTE | Can connect to TP, subscription succeeds |

Failure during startup = immediate exit (fail fast).

## Rationale

This approach was selected because:

- **Simplicity**: Complex retry logic adds code and hides problems
- **Visibility**: Fail-fast surfaces issues immediately
- **Consistency**: Aligns with ADR-003 (logging) and ADR-006 (manual replay)
- **Appropriate**: Error handling matches project maturity
- **Debuggable**: Clear logs aid understanding
- **Independent**: Each process handles its own errors

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

### 6. Shared error handling library
Rejected:
- Overkill for current scale
- Each component has different error scenarios
- Would add coupling between components

## Consequences

### Positive

- Simple, understandable error handling
- Problems surface immediately (fail fast)
- Easy to diagnose issues via logs
- No hidden retry loops masking problems
- Quote handler state machine handles recovery scenarios
- Independent processes can be restarted independently
- Low implementation overhead

### Negative / Trade-offs

- Manual restart required for some failures
- No automatic recovery from TP disconnect (RDB/RTE)
- No automatic recovery on startup (manual replay required)
- Transient errors cause data loss (by design)
- No persistent audit trail of errors
- Log format is informal (no structured logging)

These trade-offs are acceptable for the current phase.

## Implementation Checklist

### Implemented

- [x] Trade FH: Exit on startup connection failure
- [x] Trade FH: Skip malformed JSON messages
- [x] Quote FH: Exit on startup connection failure
- [x] Quote FH: Sequence gap detection and INVALID state
- [x] Quote FH: State machine (INIT → SYNCING → VALID ↔ INVALID)
- [x] TP: `.z.pc` handles subscriber disconnect
- [x] TP: `.u.sub` validates table name
- [x] TP: Logging to separate files per data type
- [x] RDB: Protected TP connection with error message
- [x] RTE: Protected TP connection with error message
- [x] RTE: Auto-initialize unknown symbols
- [x] RTE: Standalone mode for testing

### Recommended Enhancements

- [ ] Trade FH: Reconnect to Binance with backoff
- [ ] Trade FH: Reconnect to TP with backoff
- [ ] Quote FH: Reconnect to Binance with backoff
- [ ] Quote FH: Reconnect to TP with backoff
- [ ] All FH: Log with consistent format and levels
- [ ] RDB: Protected timer callback
- [ ] RDB: Log telemetry errors

### Out of Scope

- [ ] Automatic RDB/RTE reconnect to TP
- [ ] Automatic recovery on startup
- [ ] Structured logging
- [ ] External log aggregation
- [ ] Alerting
- [ ] Health check endpoints

## Future Evolution

| Enhancement | Trigger |
|-------------|---------|
| Automatic reconnection | Frequent manual restarts become painful |
| Automatic startup recovery | Production deployment |
| Structured logging | Need for log analysis or aggregation |
| Health endpoints | External monitoring integration |
| Alerting | Production deployment |
| Circuit breakers | High message rates, cascading failures |

## Links / References

- `../kdbx-real-time-architecture-reference.md` (fail-fast principle)
- `adr-001-timestamps-and-latency-measurement.md` (fhSeqNo for gap detection)
- `adr-002-feed-handler-to-kdb-ingestion-path.md` (separate processes, independent restart)
- `adr-003-tickerplant-logging-and-durability-strategy.md` (TP logging)
- `adr-004-real-time-rolling-analytics-computation.md` (validity indicators)
- `adr-006-recovery-and-replay-strategy.md` (manual replay)
- `adr-007-visualisation-and-consumption-strategy.md` (observability via dashboard)
- `adr-009-l1-order-book-architecture.md` (quote handler state machine)
