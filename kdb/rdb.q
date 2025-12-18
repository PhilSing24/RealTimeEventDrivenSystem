/ -------------------------------------------------------
/ rdb.q
/ Real-Time Database with TP subscription, timestamping,
/ and telemetry aggregation
/ -------------------------------------------------------

/ -------------------------------------------------------
/ Configuration
/ -------------------------------------------------------

/ Epoch offset: nanoseconds between 2000.01.01 and 1970.01.01
.u.epochOffset:946684800000000000j;

/ Telemetry bucket size
.rdb.telemetryBucketMs:1000;

/ Telemetry retention (15 minutes in nanoseconds)
.rdb.telemetryRetentionNs:15 * 60 * 1000000000j;

/ -------------------------------------------------------
/ Table schema (14 fields - includes rdbApplyTimeUtcNs)
/ -------------------------------------------------------

trade_binance:([]
  time:`timestamp$();
  sym:`symbol$();
  tradeId:`long$();
  price:`float$();
  qty:`float$();
  buyerIsMaker:`boolean$();
  exchEventTimeMs:`long$();
  exchTradeTimeMs:`long$();
  fhRecvTimeUtcNs:`long$();
  fhParseUs:`long$();
  fhSendUs:`long$();
  fhSeqNo:`long$();
  tpRecvTimeUtcNs:`long$();
  rdbApplyTimeUtcNs:`long$()
  );

/ -------------------------------------------------------
/ Telemetry Tables (per ADR-005)
/ -------------------------------------------------------

/ Feed handler latency aggregates
telemetry_latency_fh:([]
  bucket:`timestamp$();
  sym:`symbol$();
  parseUs_p50:`float$();
  parseUs_p95:`float$();
  parseUs_p99:`float$();
  parseUs_max:`long$();
  sendUs_p50:`float$();
  sendUs_p95:`float$();
  sendUs_p99:`float$();
  sendUs_max:`long$();
  cnt:`long$()
  );

/ End-to-end latency aggregates
telemetry_latency_e2e:([]
  bucket:`timestamp$();
  sym:`symbol$();
  fhToTpMs_p50:`float$();
  fhToTpMs_p95:`float$();
  fhToTpMs_p99:`float$();
  tpToRdbMs_p50:`float$();
  tpToRdbMs_p95:`float$();
  tpToRdbMs_p99:`float$();
  e2eMs_p50:`float$();
  e2eMs_p95:`float$();
  e2eMs_p99:`float$();
  cnt:`long$()
  );

/ Throughput metrics
telemetry_throughput:([]
  bucket:`timestamp$();
  sym:`symbol$();
  tradeCount:`long$();
  totalQty:`float$();
  totalValue:`float$()
  );

/ -------------------------------------------------------
/ Utility Functions
/ -------------------------------------------------------

/ Convert kdb timestamp to nanoseconds since Unix epoch
.rdb.tsToNs:{[ts]
  .u.epochOffset + "j"$ts - 2000.01.01D0
  };

/ Percentile function
.rdb.percentile:{[p;x]
  if[0 = n:count x; :0n];
  x:(asc x) rank:("j"$p * n - 1) & n - 1;
  x rank
  };

/ -------------------------------------------------------
/ Update handler (called by TP via pub/sub)
/ -------------------------------------------------------

.u.upd:{[tbl;data]
  / Capture RDB apply time immediately
  rdbApplyTs:.z.p;
  rdbApplyTimeUtcNs:.rdb.tsToNs[rdbApplyTs];
  
  / Append rdbApplyTimeUtcNs to the row
  data:data,rdbApplyTimeUtcNs;
  
  / Insert into table
  tbl insert data;
  };

/ -------------------------------------------------------
/ Telemetry Aggregation (1-second timer)
/ -------------------------------------------------------

.rdb.lastTelemetryBucket:0Np;

.rdb.computeTelemetry:{[]
  / Current bucket (truncated to second)
  now:.z.p;
  currentBucket:`timestamp$1000000000j * `long$now div 1000000000j;
  
  / Process previous bucket (not current, as it may be incomplete)
  bucket:currentBucket - 0D00:00:01;
  
  / Skip if we already processed this bucket
  if[bucket <= .rdb.lastTelemetryBucket; :()];
  
  / Get trades in the bucket window
  bucketStart:bucket;
  bucketEnd:bucket + 0D00:00:01;
  
  trades:select from trade_binance where time >= bucketStart, time < bucketEnd;
  
  if[0 = count trades; .rdb.lastTelemetryBucket:bucket; :()];
  
  / Compute FH latency aggregates by symbol
  fhStats:select
    parseUs_p50:.rdb.percentile[0.5; fhParseUs],
    parseUs_p95:.rdb.percentile[0.95; fhParseUs],
    parseUs_p99:.rdb.percentile[0.99; fhParseUs],
    parseUs_max:max fhParseUs,
    sendUs_p50:.rdb.percentile[0.5; fhSendUs],
    sendUs_p95:.rdb.percentile[0.95; fhSendUs],
    sendUs_p99:.rdb.percentile[0.99; fhSendUs],
    sendUs_max:max fhSendUs,
    cnt:count i
    by sym from trades;
  
  fhStats:update bucket:bucket from fhStats;
  `telemetry_latency_fh insert 0!fhStats;
  
  / Compute E2E latency aggregates by symbol
  / Calculate latencies in milliseconds
  tradesWithLatency:update
    fhToTpMs:(tpRecvTimeUtcNs - fhRecvTimeUtcNs) % 1e6,
    tpToRdbMs:(rdbApplyTimeUtcNs - tpRecvTimeUtcNs) % 1e6,
    e2eMs:(rdbApplyTimeUtcNs - fhRecvTimeUtcNs) % 1e6
    from trades;
  
  e2eStats:select
    fhToTpMs_p50:.rdb.percentile[0.5; fhToTpMs],
    fhToTpMs_p95:.rdb.percentile[0.95; fhToTpMs],
    fhToTpMs_p99:.rdb.percentile[0.99; fhToTpMs],
    tpToRdbMs_p50:.rdb.percentile[0.5; tpToRdbMs],
    tpToRdbMs_p95:.rdb.percentile[0.95; tpToRdbMs],
    tpToRdbMs_p99:.rdb.percentile[0.99; tpToRdbMs],
    e2eMs_p50:.rdb.percentile[0.5; e2eMs],
    e2eMs_p95:.rdb.percentile[0.95; e2eMs],
    e2eMs_p99:.rdb.percentile[0.99; e2eMs],
    cnt:count i
    by sym from tradesWithLatency;
  
  e2eStats:update bucket:bucket from e2eStats;
  `telemetry_latency_e2e insert 0!e2eStats;
  
  / Compute throughput by symbol
  tputStats:select
    tradeCount:count i,
    totalQty:sum qty,
    totalValue:sum price * qty
    by sym from trades;
  
  tputStats:update bucket:bucket from tputStats;
  `telemetry_throughput insert 0!tputStats;
  
  / Update last processed bucket
  .rdb.lastTelemetryBucket:bucket;
  
  / Cleanup old telemetry (retain 15 minutes)
  cutoff:now - .rdb.telemetryRetentionNs;
  delete from `telemetry_latency_fh where bucket < cutoff;
  delete from `telemetry_latency_e2e where bucket < cutoff;
  delete from `telemetry_throughput where bucket < cutoff;
  };

/ -------------------------------------------------------
/ Subscription to Tickerplant
/ -------------------------------------------------------

.rdb.connect:{[]
  -1 "Connecting to tickerplant on port 5010...";
  h:@[hopen; `::5010; {-1 "Failed to connect to TP: ",x; 0N}];
  if[null h; '"Cannot connect to tickerplant"];
  
  / Subscribe to trade_binance table
  res:h (`.u.sub; `trade_binance; `);
  -1 "Subscribed to: ", string first res;
  
  / Store handle for potential later use
  .rdb.tpHandle:h;
  };

/ -------------------------------------------------------
/ Startup
/ -------------------------------------------------------

\p 5011

-1 "RDB starting on port 5011";

/ Connect and subscribe to TP
.rdb.connect[];

/ Start telemetry timer (every 1 second)
.z.ts:{.rdb.computeTelemetry[]};
\t 1000

-1 "RDB ready - telemetry aggregation enabled (1-second buckets)";

/ -------------------------------------------------------
/ End
/ -------------------------------------------------------
