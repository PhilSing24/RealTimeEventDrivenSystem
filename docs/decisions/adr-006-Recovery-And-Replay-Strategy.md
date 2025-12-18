# ADR-006: Recovery and Replay Strategy

## Status
Accepted

## Date
2025-12-17

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

However, this project is explicitly **exploratory and incremental** in nature. The current system ingests real-time Binance trade data and focuses on:
- Architecture understanding
- Latency measurement discipline
- Real-time analytics behaviour

Key constraints from prior decisions:
- No durable TP logging (ADR-003)
- No Historical Database (ADR-003)
- Ephemeral telemetry (ADR-005)
- Async IPC with no local buffering (ADR-002)

A decision is required on what recovery capabilities, if any, are implemented.

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

The project implements a **tiered recovery model** with limited capabilities appropriate for an exploratory system.

### Recovery Capability Summary

| Level | Capability | Status |
|-------|------------|--------|
| System-wide replay (from TP logs) | Rebuild all state from durable logs | ✗ Not implemented |
| RDB recovery | Rebuild RDB from TP log or upstream | ✗ Not implemented |
| RTE recovery from RDB | Query RDB for recent trades to rebuild analytics | ✓ Partial (if RDB has data) |
| FH recovery from Binance | Replay missed data from exchange | ✗ Not available (Binance limitation) |
| Gap detection | Identify missed events via sequence numbers | ✓ Available |
| Gap recovery | Fill gaps with missed data | ✗ Not implemented |

### System-Wide Recovery

**No system-wide recovery mechanism is implemented.**

- The system operates as a **pure real-time, transient pipeline**
- On full system restart, all components resume from the live stream only
- No historical state is reconstructed
- No TP log files exist to replay

This is a direct consequence of ADR-003 (no TP logging).

### Component-Level Recovery

**RTE recovery from RDB is partially supported (ADR-004):**

On RTE restart:
1. Subscribe to tickerplant for live updates
2. Query RDB for trades within the rolling window period
3. Replay RDB data into rolling state
4. Mark analytics as invalid until window is sufficiently filled
5. Continue processing live updates

**Limitation:** If RDB is also empty (e.g., TP restart, RDB restart, or full system restart), RTE starts with empty state.

**RDB has no recovery capability:**

- RDB starts empty on restart
- No TP log to replay
- No upstream replay from Binance
- Data from before restart is permanently lost

### Upstream (Binance) Reconnect Behaviour

Binance WebSocket trade streams have specific reconnect characteristics:

| Aspect | Behaviour |
|--------|-----------|
| Reconnection | Client must reconnect and resubscribe |
| Historical replay | Not provided on standard trade stream |
| Catch-up mechanism | None; stream resumes from reconnect point |
| Gap | Data during disconnection is permanently lost |
| Alternative | REST API can fetch recent trades (not implemented) |

Binance does not replay missed messages on WebSocket reconnect. This fundamentally limits recovery options even if TP logging were enabled.

### Failure Scenario Matrix

| Failure | Data Impact | Recovery Action | Gap |
|---------|-------------|-----------------|-----|
| FH disconnects from Binance | Trades during disconnect lost | FH reconnects; resumes live stream | Permanent |
| FH disconnects from TP | Trades during disconnect lost | FH reconnects to TP; resumes publishing | Permanent |
| FH crash | Trades during downtime lost | Restart FH; reconnect to Binance | Permanent |
| TP crash | RDB/RTE lose subscription | Restart TP; subscribers reconnect; gap from crash | Permanent |
| RDB crash | All in-memory trades lost | Restart RDB; starts empty | Permanent (all prior data) |
| RTE crash | Analytics state lost | Restart RTE; query RDB; rebuild partial state | Analytics invalid until window fills |
| Full system restart | Everything lost | All components start fresh | Permanent (all prior data) |

### Gap Detection vs Gap Recovery

ADR-001 defines `fhSeqNo` (feed handler sequence number) and `tradeId` (Binance trade ID) for correlation.

| Capability | Status | Mechanism |
|------------|--------|-----------|
| Gap detection | ✓ Available | `fhSeqNo` gaps indicate missed FH events |
| Gap attribution | ✓ Available | Distinguish FH gaps from Binance gaps |
| Gap reporting | ✓ Available | Observable via telemetry (ADR-005) |
| Gap recovery | ✗ Not implemented | Gaps are permanent; no backfill |

**Gap detection logic:**

| Gap Type | Detection Method |
|----------|------------------|
| FH sequence gap | `fhSeqNo` not contiguous |
| Binance trade gap | `tradeId` not contiguous (note: Binance does not guarantee contiguous IDs) |
| Time gap | Large jump in `exchEventTimeMs` |

Gaps are logged/observable but not recoverable in the current architecture.

### Impact on Downstream Consumers

Since there is no recovery or replay mechanism, downstream consumers (RTE, dashboards) have simplified behaviour:

| Concern | Status |
|---------|--------|
| Handle late-arriving data | Not required; no replay |
| Distinguish live vs replay mode | Not required; always live |
| Idempotent processing | Not required; no duplicates from replay |
| Out-of-order handling | Not required; data flows in order |
| Gap handling | Gaps result in missing data; observable via validity flags (ADR-004) |

Consumers can assume:
- All data is live
- Data arrives in order
- No duplicates
- Gaps are permanent

### Data Loss Acceptance

The following data loss scenarios are explicitly accepted:

| Scenario | Data Lost | Acceptable Because |
|----------|-----------|-------------------|
| Network blip (FH ↔ Binance) | Seconds of trades | Exploratory project; no regulatory requirement |
| Component restart | Minutes to hours of trades | Can observe behaviour after restart |
| Full system restart | All historical data | Focus is real-time behaviour, not historical analysis |
| End of day | All data | No HDB; each session starts fresh |

## Rationale

This decision is intentional and aligned with the project goals:

- Keeps the system simple and focused
- Avoids premature optimisation and complexity
- Allows clear reasoning about live latency and flow behaviour
- Matches the transient nature of exchange WebSocket feeds
- Consistent with ADR-003 (no TP logging) and overall ephemeral stance

Recovery and replay concerns are deferred until:
- The analytics require historical continuity
- State reconstruction becomes operationally necessary
- Log-based durability is explicitly introduced

## Alternatives Considered

### 1. Implement TP logging for recovery
Rejected:
- Contradicts ADR-003 decision
- Adds complexity for exploratory project
- Latency measurement is primary goal, not durability

Remains viable for future phase if durability is required.

### 2. Use Binance REST API for gap fill
Rejected:
- Adds significant complexity
- REST and WebSocket data may have subtle differences
- Out of scope for current phase

Could be considered if gap recovery becomes important.

### 3. Local recovery log in FH
Rejected:
- Duplicates TP responsibility
- Violates separation of concerns
- Adds C++ complexity

### 4. Implement full checkpoint/snapshot recovery
Rejected:
- Significant implementation effort
- Overkill for exploratory project
- Requires coordination between components

### 5. Accept gaps silently (no detection)
Rejected:
- Lose visibility into system health
- Cannot distinguish working system from broken system
- `fhSeqNo` implementation cost is minimal

## Consequences

### Positive

- Simplified system architecture
- Faster iteration and experimentation
- No ambiguity between live vs replayed data
- Clear focus on real-time behaviour
- No complex recovery coordination logic
- Downstream consumers have simple assumptions
- Gap detection provides observability without recovery complexity

### Negative / Limitations

- Loss of analytics state on restart
- No historical backfill or gap recovery
- Not suitable for production trading or regulatory use
- RTE analytics invalid after restart until window fills
- Data gaps are permanent
- No audit trail

These limitations are acceptable for the current phase.

## Future Considerations

If recovery capabilities are required in later phases:

| Enhancement | Implementation |
|-------------|----------------|
| TP logging | Enable log writes; add replay tooling |
| RDB recovery | Replay TP log on startup |
| RTE snapshot | Periodic state persistence; load on startup |
| Gap fill via REST | Query Binance REST API for missed trades |
| Explicit recovery modes | Distinguish "live" vs "replay" processing |
| Telemetry-aware replay | Throttle replay to avoid skewing metrics |

Such changes would be captured in a new ADR and would require updates to:
- ADR-003 (logging strategy)
- ADR-005 (telemetry during replay)
- Potentially ADR-004 (RTE replay handling)

Changes would NOT require updates to:
- ADR-001 (timestamps)
- ADR-002 (ingestion path)

## Links / References

- `../kdbx-real-time-architecture-reference.md`
- `../kdbx-real-time-architecture-measurement-notes.md`
- `adr-001-timestamps-and-latency-measurement.md` (sequence numbers for gap detection)
- `adr-002-feed-handler-to-kdb-ingestion-path.md` (async IPC, no buffering)
- `adr-003-tickerplant-logging-and-durability-strategy.md` (no TP logging — foundational decision)
- `adr-004-real-time-rolling-analytics-computation.md` (RTE recovery from RDB)
- `adr-005-telemetry-and-metrics-aggregation-strategy.md` (gap observability)