# Real-Time Event-Driven System (Binance → KDB-X)

This repository explores the design and implementation of a real-time, event-driven market-data ingestion system, using Binance WebSocket trade streams as an upstream source and kdb+/KDB-X as the target analytics platform.

The focus is on architecture, timing correctness, observability, and replayability, rather than a minimal feed handler.

# Project structure

binance_feed_handler/
├── docs/
│   ├── api-binance.md
│   ├── kdbx-real-time-architecture-reference.md
│   ├── kdbx-real-time-architecture-measurement-notes.md
│   ├── decisions/
│   │   └── adr-001-timestamps-and-latency-measurement.md
│   ├── specs/
│   │   └── trades-schema.md
│   └── reference/
│       └── DataIntellect_Real_Time_KDBX.pdf
├── src/
│   ├── main.cpp
│   ├── feed_handler.cpp
│   ├── e.o
│   └── k.h
├── CMakeLists.txt
└── README.md

# What is implemented so far

## Architecture & design

Real-time KDB-X architecture patterns (feed handler, tickerplant, RDB, RTE)

Recovery, resilience, performance, IPC, monitoring considerations

Non-authoritative reference document for design trade-offs

→ docs/kdbx-real-time-architecture-reference.md

## Timing & latency measurement

Clear separation of:

Exchange timestamps

Wall-clock receive time

Monotonic receive time

Explanation of NTP/PTP effects and clock skew

Guidance for latency measurement and SLOs

→ docs/kdbx-real-time-architecture-measurement-notes.md
→ docs/decisions/adr-001-timestamps-and-latency-measurement.md

## Binance API contract

WebSocket stream behaviour (raw vs combined streams)

Envelope format, connection lifecycle, limits, ping/pong

Timestamp units and configuration

→ docs/api-binance.md

## Trade schema (draft)

Canonical internal representation of Binance trade events

Explicit naming, typing, and timestamp semantics

Designed for replay, deduplication, and downstream analytics

→ docs/specs/trades-schema.md

## Feed handler prototype

C++ feed handler using Boost.Asio / Boost.Beast

Live connection to Binance trade streams

JSON parsing via RapidJSON

Captures:

Exchange trade time

Feed-handler wall-clock receive time

Feed-handler monotonic receive time

The handler currently prints normalized trade events and timestamps to stdout.