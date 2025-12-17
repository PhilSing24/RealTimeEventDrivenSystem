# Binance WebSocket API – Feed Handler Specification

## Purpose

This document defines the external WebSocket API contract between Binance and the Feed Handler.
It describes connection endpoints, stream formats, message envelopes, payloads, limits, and
operational requirements.  

This document is **descriptive**, not interpretive.  
Transformation, normalisation, schema mapping, and timestamp semantics are defined elsewhere.

---

## Base Endpoints

The Binance WebSocket base endpoints are:

- `wss://stream.binance.com:9443`
- `wss://stream.binance.com:443`
- `wss://data-stream.binance.vision` (market data only)

A single WebSocket connection is valid for **24 hours**.  
Connections are disconnected automatically after this period.

---

## Stream Access Modes

### Raw Streams

Raw streams are accessed via:

