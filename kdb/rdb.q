/ =============================================================================
/ rdb.q - Real-Time Database
/ =============================================================================
/
/ Purpose:
/   In-memory storage for real-time trade data with telemetry aggregation.
/   Receives trades from Tickerplant, adds timestamp, computes latency metrics.
/
/ Architecture role:
/   TP → [RDB] → Dashboards (queries)
/              → Telemetry tables (aggregated metrics)
/
/ Key responsibilities:
/   - Receive and store trade events from TP
/   - Capture RDB apply timestamp (rdbApplyTimeUtcNs)
/   - Compute latency telemetry (p50/p95/p99) every second
/   - Compute throughput metrics per symbol
/   - Serve dashboard queries
/
/ Design decisions:
/   - In-memory only, no persistence (ADR-003)
/   - 1-second telemetry buckets (ADR-005)
/   - 15-minute telemetry retention
/   - Percentiles computed via sorted list indexing
/
/ @see docs/decisions/adr-003-Tickerplant-Logging-and-Durability-Strategy.md
/ @see docs/decisions/adr-005-Telemetry-And-Metrics-Aggregation-Strategy.md
/ =============================================================================

/ -----------------------------------------------------------------------------
/ Configuration
/ -----------------------------------------------------------------------------

/ Epoch offset: nanoseconds between kdb+ epoch (2000.01.01) and Unix (1970.01.01)
.u.epochOffset:946684800000000000j;

/ Telemetry bucket size in milliseconds (1 second)
.rdb.telemetryBucketMs:1000;

/ Telemetry retention period in nanoseconds (15 minutes)
/ Older telemetry data is deleted to limit memory usage
.rdb.telemetryRetentionNs:15 * 60 * 1000000000j;

/ -----------------------------------------------------------------------------
/ Table Schema - Trade Data
/ -----------------------------------------------------------------------------
/ Full trade record with 14 fields (includes RDB timestamp)
/
/ Fields 1-12: From Feed Handler (via TP)
/ Field 13: tpRecvTimeUtcNs - Added by Tickerplant
/ Field 14: rdbApplyTimeUtcNs - Added by RDB (this process)

trade_binance:([]
  time:`timestamp$();           / FH receive time as kdb timestamp
  sym:`symbol$();               / Trading symbol (BTCUSDT, ETHUSDT)
  tradeId:`long$();             / Binance trade ID
  price:`float$();              / Trade price
  qty:`float$();                / Trade quantity
  buyerIsMaker:`boolean$();     / True if buyer was maker
  exchEventTimeMs:`long$();     / Binance event time (ms since Unix epoch)
  exchTradeTimeMs:`long$();     / Binance trade time (ms since Unix epoch)
  fhRecvTimeUtcNs:`long$();     / FH receive time (ns since Unix epoch)
  fhParseUs:`long$();           / FH parse duration (microseconds)
  fhSendUs:`long$();            / FH send prep duration (microseconds)
  fhSeqNo:`long$();             / FH sequence number (for gap detection)
  tpRecvTimeUtcNs:`long$();     / TP receive time (ns since Unix epoch)
  rdbApplyTimeUtcNs:`long$()    / RDB apply time (ns since Unix epoch) - ADDED HERE
  );

/ -----------------------------------------------------------------------------
/ Telemetry Tables (per ADR-005)
/ -----------------------------------------------------------------------------

/ Feed handler latency aggregates (per 1-second bucket, per symbol)
/ Captures parse and send latency distribution
telemetry_latency_fh:([]
  bucket:`timestamp$();         / Start of 1-second bucket
  sym:`symbol$();               / Symbol
  parseUs_p50:`float$();        / Median parse latency
  parseUs_p95:`float$();        / 95th percentile parse latency
  parseUs_p99:`float$();        / 99th percentile parse latency
  parseUs_max:`long$();         / Maximum parse latency
  sendUs_p50:`float$();         / Median send latency
  sendUs_p95:`float$();         / 95th percentile send latency
  sendUs_p99:`float$();         / 99th percentile send latency
  sendUs_max:`long$();          / Maximum send latency
  cnt:`long$()                  / Number of trades in bucket
  );

/ End-to-end latency aggregates (per 1-second bucket, per symbol)
/ Measures latency between pipeline stages
telemetry_latency_e2e:([]
  bucket:`timestamp$();         / Start of 1-second bucket
  sym:`symbol$();               / Symbol
  fhToTpMs_p50:`float$();       / Median FH-to-TP latency (ms)
  fhToTpMs_p95:`float$();       / 95th percentile FH-to-TP latency
  fhToTpMs_p99:`float$();       / 99th percentile FH-to-TP latency
  tpToRdbMs_p50:`float$();      / Median TP-to-RDB latency (ms)
  tpToRdbMs_p95:`float$();      / 95th percentile TP-to-RDB latency
  tpToRdbMs_p99:`float$();      / 99th percentile TP-to-RDB latency
  e2eMs_p50:`float$();          / Median end-to-end latency (FH to RDB)
  e2eMs_p95:`float$();          / 95th percentile E2E latency
  e2eMs_p99:`float$();          / 99th percentile E2E latency
  cnt:`long$()                  / Number of trades in bucket
  );

/ Throughput metrics (per 1-second bucket, per symbol)
telemetry_throughput:([]
  bucket:`timestamp$();         / Start of 1-second bucket
  sym:`symbol$();               / Symbol
  tradeCount:`long$();          / Number of trades
  totalQty:`float$();           / Sum of trade quantities
  totalValue:`float$()          / Sum of (price * qty)
  );

/ -----------------------------------------------------------------------------
/ Utility Functions
/ -----------------------------------------------------------------------------

/ Convert kdb+ timestamp to nanoseconds since Unix epoch
/ @param ts - kdb+ timestamp (e.g., .z.p)
/ @return Nanoseconds since 1970.01.01 (Unix epoch)
.rdb.tsToNs:{[ts]
  .u.epochOffset + "j"$ts - 2000.01.01D0
  };

/ Percentile function
/ Computes percentile p from list x using nearest-rank method
/ @param p - Percentile (0.0 to 1.0, e.g., 0.95 for 95th percentile)
/ @param x - List of numeric values
/ @return The value at the given percentile
.rdb.pctl:{[p;x]
  if[0 = n:count x; :0n];           / Return null if empty list
  idx:0 | ("j"$ p * n - 1) & n - 1; / Calculate index, clamp to valid range
  (asc x) idx                        / Sort and return value at index
  };

/ -----------------------------------------------------------------------------
/ Update Handler (called by TP via pub/sub)
/ -----------------------------------------------------------------------------

/ Receive update from Tickerplant
/ Adds RDB timestamp and inserts into trade table
/ @param tbl - Table name (always `trade_binance)
/ @param data - Row data (13 fields from TP)
.u.upd:{[tbl;data]
  / Capture RDB apply time immediately (latency measurement point)
  rdbApplyTs:.z.p;
  rdbApplyTimeUtcNs:.rdb.tsToNs[rdbApplyTs];
  
  / Append rdbApplyTimeUtcNs to the row (13 -> 14 fields)
  data:data,rdbApplyTimeUtcNs;
  
  / Insert into table (data is now query-consistent)
  tbl insert data;
  };

/ -----------------------------------------------------------------------------
/ Telemetry Aggregation (1-second timer)
/ -----------------------------------------------------------------------------

/ Track last processed bucket to avoid reprocessing
.rdb.lastTelemetryBucket:0Np;

/ Main telemetry computation function
/ Called every second by timer (.z.ts)
/ Computes percentiles and throughput for the previous 1-second bucket
.rdb.computeTelemetry:{[]
  / Current time and bucket (truncated to second boundary)
  now:.z.p;
  currentBucket:`timestamp$1000000000j * `long$now div 1000000000j;
  
  / Process previous bucket (not current, as it may be incomplete)
  / E.g., at 10:00:05.500, process 10:00:04.000-10:00:05.000
  bucket:currentBucket - 0D00:00:01;
  
  / Skip if we already processed this bucket
  if[bucket <= .rdb.lastTelemetryBucket; :()];
  
  / Define bucket time window
  bucketStart:bucket;
  bucketEnd:bucket + 0D00:00:01;
  
  / Get trades in the bucket window
  trades:select from trade_binance where time >= bucketStart, time < bucketEnd;
  
  / Skip if no trades in this bucket
  if[0 = count trades; .rdb.lastTelemetryBucket:bucket; :()];
  
  / Get unique symbols in this bucket
  syms:exec distinct sym from trades;
  
  / ---- Compute FH latency stats per symbol ----
  / For each symbol: extract parse/send times, compute percentiles
  fhRows:{[bucket;trades;s]
    t:select fhParseUs, fhSendUs from trades where sym = s;
    parseVals:t[`fhParseUs];
    sendVals:t[`fhSendUs];
    n:count t;
    / Build row as dictionary
    `bucket`sym`parseUs_p50`parseUs_p95`parseUs_p99`parseUs_max`sendUs_p50`sendUs_p95`sendUs_p99`sendUs_max`cnt !
      (bucket; s;
       `float$.rdb.pctl[0.5; parseVals]; `float$.rdb.pctl[0.95; parseVals]; `float$.rdb.pctl[0.99; parseVals]; max parseVals;
       `float$.rdb.pctl[0.5; sendVals]; `float$.rdb.pctl[0.95; sendVals]; `float$.rdb.pctl[0.99; sendVals]; max sendVals;
       n)
    }[bucket;trades] each syms;
  
  `telemetry_latency_fh insert fhRows;
  
  / ---- Compute E2E latency stats per symbol ----
  / Calculates FH→TP, TP→RDB, and total E2E latencies
  e2eRows:{[bucket;trades;s]
    t:select fhRecvTimeUtcNs, tpRecvTimeUtcNs, rdbApplyTimeUtcNs from trades where sym = s;
    fhRecv:t[`fhRecvTimeUtcNs];
    tpRecv:t[`tpRecvTimeUtcNs];
    rdbApply:t[`rdbApplyTimeUtcNs];
    / Convert nanoseconds to milliseconds for readability
    fhToTp:(tpRecv - fhRecv) % 1e6;      / FH → TP latency (ms)
    tpToRdb:(rdbApply - tpRecv) % 1e6;   / TP → RDB latency (ms)
    e2e:(rdbApply - fhRecv) % 1e6;       / Total E2E latency (ms)
    n:count t;
    `bucket`sym`fhToTpMs_p50`fhToTpMs_p95`fhToTpMs_p99`tpToRdbMs_p50`tpToRdbMs_p95`tpToRdbMs_p99`e2eMs_p50`e2eMs_p95`e2eMs_p99`cnt !
      (bucket; s;
       .rdb.pctl[0.5; fhToTp]; .rdb.pctl[0.95; fhToTp]; .rdb.pctl[0.99; fhToTp];
       .rdb.pctl[0.5; tpToRdb]; .rdb.pctl[0.95; tpToRdb]; .rdb.pctl[0.99; tpToRdb];
       .rdb.pctl[0.5; e2e]; .rdb.pctl[0.95; e2e]; .rdb.pctl[0.99; e2e];
       n)
    }[bucket;trades] each syms;
  
  `telemetry_latency_e2e insert e2eRows;
  
  / ---- Compute throughput per symbol ----
  tputRows:{[bucket;trades;s]
    t:select price, qty from trades where sym = s;
    prices:t[`price];
    qtys:t[`qty];
    `bucket`sym`tradeCount`totalQty`totalValue !
      (bucket; s; count t; sum qtys; sum prices * qtys)
    }[bucket;trades] each syms;
  
  `telemetry_throughput insert tputRows;
  
  / Update last processed bucket
  .rdb.lastTelemetryBucket:bucket;
  
  / ---- Cleanup old telemetry (retain 15 minutes) ----
  / Prevents unbounded memory growth
  cutoff:now - .rdb.telemetryRetentionNs;
  delete from `telemetry_latency_fh where bucket < cutoff;
  delete from `telemetry_latency_e2e where bucket < cutoff;
  delete from `telemetry_throughput where bucket < cutoff;
  };

/ -----------------------------------------------------------------------------
/ Subscription to Tickerplant
/ -----------------------------------------------------------------------------

/ Connect to Tickerplant and subscribe to trade updates
.rdb.connect:{[]
  -1 "Connecting to tickerplant on port 5010...";
  
  / Attempt connection with error handling
  / @[f;x;e] - try f[x], if error run e with error message
  h:@[hopen; `::5010; {-1 "Failed to connect to TP: ",x; 0N}];
  if[null h; '"Cannot connect to tickerplant"];
  
  / Subscribe to trade_binance table
  / This registers our handle with TP, so TP will send us updates
  res:h (`.u.sub; `trade_binance; `);
  -1 "Subscribed to: ", string first res;
  
  / Store handle for potential later use (e.g., recovery)
  .rdb.tpHandle:h;
  };

/ -----------------------------------------------------------------------------
/ Startup
/ -----------------------------------------------------------------------------

/ Set listening port (for dashboard queries)
\p 5011

-1 "RDB starting on port 5011";

/ Connect and subscribe to TP
.rdb.connect[];

/ Start telemetry timer
/ .z.ts is called every \t milliseconds
/ Computes telemetry aggregates for completed 1-second buckets
.z.ts:{.rdb.computeTelemetry[]};
\t 1000

-1 "RDB ready - telemetry aggregation enabled (1-second buckets)";

/ -----------------------------------------------------------------------------
/ End
/ -----------------------------------------------------------------------------
