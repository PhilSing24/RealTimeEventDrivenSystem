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

/ Telemetry retention (15 minutes)
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

/ Percentile function (takes percentile p and list x)
.rdb.pctl:{[p;x]
  if[0 = n:count x; :0n];
  idx:0 | ("j"$ p * n - 1) & n - 1;
  (asc x) idx
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
  
  / Get unique symbols in this bucket
  syms:exec distinct sym from trades;
  
  / Compute FH latency stats per symbol
  fhRows:{[bucket;trades;s]
    t:select fhParseUs, fhSendUs from trades where sym = s;
    parseVals:t[`fhParseUs];
    sendVals:t[`fhSendUs];
    n:count t;
    `bucket`sym`parseUs_p50`parseUs_p95`parseUs_p99`parseUs_max`sendUs_p50`sendUs_p95`sendUs_p99`sendUs_max`cnt !
      (bucket; s;
       `float$.rdb.pctl[0.5; parseVals]; `float$.rdb.pctl[0.95; parseVals]; `float$.rdb.pctl[0.99; parseVals]; max parseVals;
       `float$.rdb.pctl[0.5; sendVals]; `float$.rdb.pctl[0.95; sendVals]; `float$.rdb.pctl[0.99; sendVals]; max sendVals;
       n)
    }[bucket;trades] each syms;
  
  `telemetry_latency_fh insert fhRows;
  
  / Compute E2E latency stats per symbol
  e2eRows:{[bucket;trades;s]
    t:select fhRecvTimeUtcNs, tpRecvTimeUtcNs, rdbApplyTimeUtcNs from trades where sym = s;
    fhRecv:t[`fhRecvTimeUtcNs];
    tpRecv:t[`tpRecvTimeUtcNs];
    rdbApply:t[`rdbApplyTimeUtcNs];
    fhToTp:(tpRecv - fhRecv) % 1e6;
    tpToRdb:(rdbApply - tpRecv) % 1e6;
    e2e:(rdbApply - fhRecv) % 1e6;
    n:count t;
    `bucket`sym`fhToTpMs_p50`fhToTpMs_p95`fhToTpMs_p99`tpToRdbMs_p50`tpToRdbMs_p95`tpToRdbMs_p99`e2eMs_p50`e2eMs_p95`e2eMs_p99`cnt !
      (bucket; s;
       .rdb.pctl[0.5; fhToTp]; .rdb.pctl[0.95; fhToTp]; .rdb.pctl[0.99; fhToTp];
       .rdb.pctl[0.5; tpToRdb]; .rdb.pctl[0.95; tpToRdb]; .rdb.pctl[0.99; tpToRdb];
       .rdb.pctl[0.5; e2e]; .rdb.pctl[0.95; e2e]; .rdb.pctl[0.99; e2e];
       n)
    }[bucket;trades] each syms;
  
  `telemetry_latency_e2e insert e2eRows;
  
  / Compute throughput per symbol
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
