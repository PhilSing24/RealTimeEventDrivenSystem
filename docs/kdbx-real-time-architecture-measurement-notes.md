# Latency Service-Level Objectives (SLOs) and Measurement Notes (Companion)

This document is a companion to `kdbx-real-time-architecture-reference.md`.  
It captures practical guidance on how latency SLOs and latency measurement are defined and implemented for this project.

## SLO Expression

Latency should be tracked using percentiles over a defined rolling window:

- p50: typical latency (equivalent to the median)
- p95: majority-case tail
- p99: operationally significant tail
- p99.9 (optional): extreme tail (only if required)

Recommended rolling windows:
- 1-minute rolling: incident detection
- 15-minute rolling: stable trend and planning

SLOs should explicitly state:
- which message types are included (trades/quotes/book)
- which symbol universe is included
- whether reconnect/recovery bursts are included

## Measurement Points

Recommended timestamps (capture what is feasible; not all points are mandatory):

- t_exchange_event: upstream event time (if provided by Binance / upstream source)
- t_fh_recv: feed handler receive time
- t_fh_parsed: feed handler parse/normalise complete
- t_fh_sent: feed handler publish initiated
- t_tp_recv: tickerplant receive time
- t_tp_log: tickerplant log append complete (durability boundary, if used)
- t_rdb_apply: RDB apply complete (query-consistent)
- t_rte_publish: derived analytic published / query-consistent
- t_consume: downstream consumer receives/uses update (if instrumented)

Derive segment latencies such as:
- fh_parse = t_fh_parsed - t_fh_recv
- fh_send_overhead = t_fh_sent - t_fh_parsed
- tp_log = t_tp_log - t_tp_recv
- e2e_system = t_rte_publish - t_fh_recv (or to t_consume when available)

## Clocking and Skew

Use two notions of time:

- Monotonic time (duration clock) for segment timing within a process/host
- Wall-clock time for cross-process correlation

Clock synchronisation:
- NTP is generally sufficient for segment latency analysis and millisecond-scale end-to-end reporting.
- PTP is required if cross-host end-to-end latency must be trusted at sub-millisecond precision.

Skew handling:
- Record clock quality telemetry (offset, sync state).
- If clock offset exceeds a defined threshold, treat cross-host end-to-end latency as unreliable and rely on segment metrics.

## Correlation

To correlate events across components, carry:
- a sequence number per stream/table and/or
- a correlation identifier

This supports:
- gap detection
- replay validation
- consistent latency attribution during reconnect and recovery scenarios

NTP: Network Time Protocol
PTP: Precision Time Protocol, IEEE 1588
