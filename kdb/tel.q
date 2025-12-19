/ tel.q - Telemetry Aggregation Process

/ Configuration
.tel.cfg.port:5013;
.tel.cfg.rdbPort:5011;
.tel.cfg.rtePort:5012;
.tel.cfg.bucketSec:5;
.tel.cfg.retentionMin:15;

.tel.cfg.bucketNs:.tel.cfg.bucketSec * 1000000000j;
.tel.cfg.bucketSpan:`timespan$.tel.cfg.bucketNs;
.tel.cfg.timerMs:.tel.cfg.bucketSec * 1000;
.tel.cfg.retentionNs:.tel.cfg.retentionMin * 60 * 1000000000j;

/ Telemetry Tables
telemetry_latency_fh:([]
  bucket:`timestamp$(); sym:`symbol$();
  parseUs_p50:`float$(); parseUs_p95:`float$(); parseUs_max:`long$();
  sendUs_p50:`float$(); sendUs_p95:`float$(); sendUs_max:`long$();
  cnt:`long$()
  );

telemetry_latency_e2e:([]
  bucket:`timestamp$(); sym:`symbol$();
  fhToTpMs_p50:`float$(); fhToTpMs_p95:`float$(); fhToTpMs_max:`float$();
  tpToRdbMs_p50:`float$(); tpToRdbMs_p95:`float$(); tpToRdbMs_max:`float$();
  e2eMs_p50:`float$(); e2eMs_p95:`float$(); e2eMs_max:`float$();
  cnt:`long$()
  );

telemetry_throughput:([]
  bucket:`timestamp$(); sym:`symbol$();
  tradeCount:`long$(); totalQty:`float$(); totalValue:`float$()
  );

telemetry_analytics_health:([]
  bucket:`timestamp$(); sym:`symbol$();
  isValid:`boolean$(); fillPct:`float$();
  tradeCount5m:`long$(); avgPrice5m:`float$()
  );

/ Percentile function
.tel.percentile:{[p;x]
  if[0 = n:count x; :0n];
  idx:0 | ("j"$p * n - 1) & n - 1;
  `float$(asc x) idx
  };

/ Safe query - returns empty on error
.tel.safeQuery:{[port;query]
  addr:`$"::",string port;
  h:@[hopen; addr; {0N}];
  if[null h; :()];
  res:@[h; query; {-1 "Query error: ",x; ()}];
  @[hclose; h; {}];
  res
  };

/ Telemetry computation
.tel.lastBucket:0Np;

.tel.compute:{[]
  now:.z.p;
  currentBucket:`timestamp$.tel.cfg.bucketNs * `long$now div .tel.cfg.bucketNs;
  bucket:currentBucket - .tel.cfg.bucketSpan;
  
  if[bucket <= .tel.lastBucket; :()];
  
  bucketStart:bucket;
  bucketEnd:bucket + .tel.cfg.bucketSpan;
  
  query:"select from trade_binance where time >= ",string[bucketStart],", time < ",string[bucketEnd];
  trades:.tel.safeQuery[.tel.cfg.rdbPort; query];
  
  if[0 < count trades;
    / FH latency
    fhStats:select
      parseUs_p50:.tel.percentile[0.5; fhParseUs],
      parseUs_p95:.tel.percentile[0.95; fhParseUs],
      parseUs_max:max fhParseUs,
      sendUs_p50:.tel.percentile[0.5; fhSendUs],
      sendUs_p95:.tel.percentile[0.95; fhSendUs],
      sendUs_max:max fhSendUs,
      cnt:count i
      by sym from trades;
    fhStats:update bucket:bucket from fhStats;
    `telemetry_latency_fh insert `bucket xcols 0!fhStats;
    
    / E2E latency
    tradesWithLatency:update
      fhToTpMs:(tpRecvTimeUtcNs - fhRecvTimeUtcNs) % 1e6,
      tpToRdbMs:(rdbApplyTimeUtcNs - tpRecvTimeUtcNs) % 1e6,
      e2eMs:(rdbApplyTimeUtcNs - fhRecvTimeUtcNs) % 1e6
      from trades;
    e2eStats:select
      fhToTpMs_p50:.tel.percentile[0.5; fhToTpMs],
      fhToTpMs_p95:.tel.percentile[0.95; fhToTpMs],
      fhToTpMs_max:max fhToTpMs,
      tpToRdbMs_p50:.tel.percentile[0.5; tpToRdbMs],
      tpToRdbMs_p95:.tel.percentile[0.95; tpToRdbMs],
      tpToRdbMs_max:max tpToRdbMs,
      e2eMs_p50:.tel.percentile[0.5; e2eMs],
      e2eMs_p95:.tel.percentile[0.95; e2eMs],
      e2eMs_max:max e2eMs,
      cnt:count i
      by sym from tradesWithLatency;
    e2eStats:update bucket:bucket from e2eStats;
    `telemetry_latency_e2e insert `bucket xcols 0!e2eStats;
    
    / Throughput
    tputStats:select tradeCount:count i, totalQty:sum qty, totalValue:sum price * qty by sym from trades;
    tputStats:update bucket:bucket from tputStats;
    `telemetry_throughput insert `bucket xcols 0!tputStats;
  ];
  
  / Analytics health from RTE
  analytics:.tel.safeQuery[.tel.cfg.rtePort; "select from rollAnalytics"];
  if[0 < count analytics;
    healthStats:select sym, isValid, fillPct, tradeCount5m, avgPrice5m from analytics;
    healthStats:update bucket:bucket from healthStats;
    `telemetry_analytics_health insert `bucket xcols healthStats;
  ];
  
  .tel.lastBucket:bucket;
  
  / Cleanup old
  cutoff:now - .tel.cfg.retentionNs;
  delete from `telemetry_latency_fh where bucket < cutoff;
  delete from `telemetry_latency_e2e where bucket < cutoff;
  delete from `telemetry_throughput where bucket < cutoff;
  delete from `telemetry_analytics_health where bucket < cutoff;
  };

\p 5013
-1 "TEL starting on port 5013";
-1 "Bucket: ",string[.tel.cfg.bucketSec],"s | Retention: ",string[.tel.cfg.retentionMin],"min";
.z.ts:{.tel.compute[]};
system "t ",string .tel.cfg.timerMs;
-1 "TEL ready - querying RDB:",string[.tel.cfg.rdbPort]," RTE:",string[.tel.cfg.rtePort];
