# Real-Time Event-Driven Market Data System (KDB-X Inspired)

## Overview

This project is an exploratory, end-to-end implementation of a **real-time, event-driven market data pipeline**, inspired by the paper:

**_Building Real Time Event Driven KDB-X Systems_ (Data Intellect)**

The objective is not to reproduce a full production system, but to **design, reason about, and incrementally build** a minimal yet realistic architecture reflecting best practices used in low-latency financial systems.

The project intentionally separates:

- Architecture reasoning
- Measurement discipline
- Explicit design decisions
- Implementation

This ensures that each step is understandable, reviewable, and resilient to accidental architectural drift.

---

## Objectives

The system aims to:

- Ingest **real-time trade data** from Binance WebSocket streams (BTCUSDT, ETHUSDT)
- Process events in an **event-driven** manner
- Publish events into a **kdb+ tickerplant via IPC**
- Define and enforce a **canonical trade schema**
- Compute **rolling analytics** (e.g. average price over the last *N* minutes)
- Capture and reason about **latency** using disciplined, architecture-aware measurement

---

## Documentation-First Approach

This project intentionally starts with **documentation and decisions before code**.

Documentation is treated as part of the system, not as an afterthought.

---

## Architecture Reference

**`docs/kdbx-real-time-architecture-reference.md`**

A structured, LLM-friendly extraction of architectural patterns, design trade-offs, and component responsibilities from the original Data Intellect paper.

This document:
- Does **not** prescribe an implementation
- Serves as a navigable reference for architecture discussions
- Provides the conceptual foundation for all subsequent decisions

---

## Measurement Discipline

**`docs/kdbx-real-time-architecture-measurement-notes.md`**

Defines how latency is expressed, measured, and interpreted in this project, including:

- Latency SLO expression (p50 / p95 / p99)
- Measurement points across components
- Monotonic vs wall-clock time usage
- Clock synchronisation assumptions
- Correlation and skew handling

This ensures that performance discussions are precise, reproducible, and meaningful.

---

## Architecture Decision Records (ADRs)

All non-trivial design choices are captured as **Architecture Decision Records** under:
docs/decisions/


ADRs:
- Make assumptions explicit
- Document trade-offs and consequences
- Prevent accidental architecture drift
- Allow decisions to evolve consciously

Key ADRs cover:
- Timestamping and latency measurement
- Feed handler → tickerplant ingestion via IPC
- Canonical trade schema
- Telemetry vs market data separation
- Recovery scope
- Visualisation strategy

---

## Canonical Schema

**`docs/specs/trades-schema.md`**

Defines the canonical schema for Binance trade events as stored in kdb+/KDB-X, including:

- Naming conventions
- Keys and uniqueness
- Timestamp semantics
- Separation of business data and telemetry

---

## Current Implementation Status

### Completed

- C++ project setup using **CMake** (WSL / Ubuntu 22.04)
- WebSocket ingestion using **Boost.Beast / Boost.Asio**
- TLS support via **OpenSSL**
- JSON parsing via **RapidJSON**
- Real-time ingestion of Binance trade streams
- Capture of:
  - Exchange timestamps
  - Feed-handler wall-clock timestamps
  - Feed-handler monotonic timing
- **IPC publication into a running kdb+ tickerplant**
- **Persistence of live trade data into `trade_binance`**
- Verified end-to-end ingestion:
  - Binance → Feed Handler → Tickerplant

### Not Yet Implemented

- RDB processes and windowed analytics
- Telemetry aggregation tables
- Recovery and replay mechanisms
- Dashboards (KX Dashboards)

These are intentionally deferred until ingestion, schema, and measurement are fully validated.

---

## Design Philosophy

- Event-driven, not batch
- Measure before optimising
- Separate correctness from performance
- Prefer explicit decisions over implicit assumptions
- Documentation is part of the system

---

## Project Structure

```text
.
├── CMakeLists.txt
├── src/
│   ├── main.cpp
│   └── feed_handler.cpp
├── kdb/
│   └── tp.q
├── docs/
│   ├── api-binance.md
│   ├── kdbx-real-time-architecture-reference.md
│   ├── kdbx-real-time-architecture-measurement-notes.md
│   ├── specs/
│   │   └── trades-schema.md
│   └── decisions/
│       ├── adr-001-timestamps-and-latency-measurement.md
│       ├── adr-002-feed-handler-to-tickerplant.md
│       ├── adr-003-ingestion-without-logfile.md
│       ├── adr-004-schema-normalisation.md
│       ├── adr-005-telemetry-vs-market-data.md
│       ├── adr-006-recovery-scope.md
│       └── adr-007-visualisation-strategy.md

