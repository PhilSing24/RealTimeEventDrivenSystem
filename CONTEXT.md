# CONTEXT.md - Project Status for Claude Sessions

*Last updated: 2025-12-24*

## Project Overview

Real-time Binance trade feed → C++ Feed Handler → kdb+ pipeline (TP → RDB → RTE)

## Architecture

```
Binance WebSocket ──► FH (C++) ──► TP:5010 ──┬──► RDB:5011 (storage + telemetry)
                                             │
                                             └──► RTE:5012 (rolling analytics)
```

## Component Status

| File | Purpose | Status |
|------|---------|--------|
| `src/feed_handler.cpp` | WebSocket client, JSON parse, IPC publish | ✓ Complete |
| `kdb/tp.q` | Tickerplant with pub/sub and logging | ✓ Complete |
| `kdb/rdb.q` | Storage + telemetry aggregation | ✓ Complete |
| `kdb/rte.q` | Rolling analytics (5-min window) | ✓ Complete |
| `kdb/replay.q` | Log replay tool | ✓ Complete |

## Recent Changes

- **2025-12-24**: Added TP logging and replay tool
  - TP writes binary logs to `logs/` (daily rotation)
  - `replay.q` replays at 447K msg/s
  - Standalone mode (`-standalone` flag) for RTE
- **2025-12-24**: Updated ADR-003 and ADR-006 to reflect logging/replay

## Open Issues / Next Steps

1. [ ] KX Dashboards visualization
2. [ ] Automatic RDB/RTE recovery from TP log on startup
3. [ ] Log retention/cleanup policy

## Key Technical Details

### TP Log Format
- Binary IPC format (no 8-byte header)
- Fixed 145-byte messages
- Path: `logs/YYYY.MM.DD.log`
- Read with custom parser (add `0x0100000099000000` header, then `-9!`)

### Replay Usage
```bash
q kdb/rte.q -standalone    # No TP connection
q kdb/replay.q -port 5012
.replay.run[]
```

### RTE Standalone Mode
```q
.rte.cfg.standalone:0b;
args:.Q.opt .z.x;
if[`standalone in key args; .rte.cfg.standalone:1b];
```

## Performance Baselines

| Metric | Value |
|--------|-------|
| Replay throughput | 447K msg/s |
| Live throughput | ~50-100 trades/sec |
| Log message size | 145 bytes |

## Useful Commands

```bash
# Start full pipeline
./start.sh

# Stop all
./stop.sh

# Manual start
q kdb/tp.q          # Terminal 1
q kdb/rdb.q         # Terminal 2
q kdb/rte.q         # Terminal 3
./build/binance_feed_handler  # Terminal 4

# Replay testing
q kdb/rte.q -standalone
q kdb/replay.q -port 5012
```

## Key Decisions Summary

| Decision | Choice | ADR |
|----------|--------|-----|
| Durability | Optional TP logging (default: enabled) | ADR-003 |
| Recovery | Replay from TP log | ADR-006 |
| Analytics | Tick-by-tick, 5-min rolling window | ADR-004 |
| Telemetry | 1-sec buckets, 15-min retention | ADR-005 |

## Files to Upload at Session Start

1. This file (`CONTEXT.md`)
2. Any files being actively worked on
3. Relevant ADRs if discussing architecture
