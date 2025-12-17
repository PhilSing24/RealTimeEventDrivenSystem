# ADR-007: Visualisation and Consumption Strategy

## Status
Accepted

## Date
2025-12-17

## Context

The system produces:
- Real-time market data (Binance trades)
- Derived analytics (e.g. rolling average price)
- Telemetry and latency metrics

These outputs must be:
- Observable by humans
- Suitable for operational inspection
- Easy to iterate on during development

Multiple visualisation approaches are possible, including:
- Custom UI builds
- External BI tools
- Streaming dashboards
- Built-in KDB-X visualisation tooling

## Decision

The project will use **KX Dashboards** as the primary visualisation and consumption mechanism.

Specifically:
- Market data and derived analytics will be visualised in KX Dashboards
- Telemetry and latency metrics will be visualised alongside business metrics
- Initial dashboards will use **polling-based queries**
- Streaming visualisations may be introduced later if required

## Scope of Visualisation

Dashboards will display, at minimum, the following **per symbol (BTCUSDT, ETHUSDT)**:

### Market Metrics
- **Last traded price**
- **Rolling average price** (over the configured window, e.g. last N minutes)
- Trade rate (events/sec)

### Telemetry Metrics
- Feed handler latency percentiles (p50 / p95 / p99)
- Event throughput
- Basic health indicators (e.g. data freshness)

The intent is to allow immediate visual comparison between:
- The most recent market price
- The smoothed analytical view (rolling average)

## Rationale

KX Dashboards:
- Are native to the KDB-X ecosystem
- Require minimal integration effort
- Support time-series and real-time analytics well
- Are well-suited for exploratory and diagnostic workflows

Polling is chosen initially because:
- It is simpler to implement
- It avoids premature optimisation
- It is sufficient for human-scale update rates

## Intended Usage

Dashboards are intended for:
- Development validation
- Real-time behaviour inspection
- Latency and performance reasoning
- Architecture exploration

They are **not** intended as end-user trading interfaces.

## Consequences

### Positive
- Rapid feedback during development
- Clear visibility into both raw and derived data
- Tight integration with kdb analytics

### Trade-offs
- Polling introduces redundant queries
- Dashboards are not optimised for large user populations
- Fine-grained UI customisation is limited

These trade-offs are acceptable for the current phase.

## Future Considerations

Potential future evolutions include:
- Streaming dashboards for higher update fidelity
- Dedicated UI cache layer
- External visualisation tools (Grafana, custom web UI)

Any such change will be documented via a new ADR.

## Links / References
- `docs/kdbx-real-time-architecture-reference.md`
- `docs/kdbx-real-time-architecture-measurement-notes.md`
- `docs/decisions/adr-005-telemetry-and-metrics-aggregation-strategy.md`
