/ rte2.q - Real-Time Engine v2 (bucketed aggregation)
/ Usage: q rte2.q -standalone

.rte2.cfg.port:5014;
.rte2.cfg.tpPort:5010;
.rte2.cfg.windowNs:5 * 60 * 1000000000j;
.rte2.cfg.bucketNs:1000000000j;
.rte2.cfg.validityThreshold:0.5;
.rte2.cfg.standalone:0b;

args:.Q.opt .z.x;
if[`standalone in key args; .rte2.cfg.standalone:1b];

.rte2.buckets:(`symbol$())!();

rollAnalytics2:([sym:`u#`symbol$()] lastPrice:`float$(); avgPrice5m:`float$(); tradeCount5m:`long$(); isValid:`boolean$(); fillPct:`float$(); windowStart:`timestamp$(); updateTime:`timestamp$());

.rte2.initBuckets:{[s] .rte2.buckets[s]:([] bucket:`timestamp$(); sumPrice:`float$(); cnt:`long$())};

.rte2.getBucket:{[t] `timestamp$(.rte2.cfg.bucketNs) * floor (`long$t) % .rte2.cfg.bucketNs};

.rte2.evict:{[s;now] cutoff:now - .rte2.cfg.windowNs; .rte2.buckets[s]:select from .rte2.buckets[s] where bucket >= cutoff};

.rte2.addTrade:{[s;t;p] b:.rte2.getBucket[t]; buckets:.rte2.buckets[s]; idx:exec i from buckets where bucket = b; $[0 < count idx; .rte2.buckets[s][first idx;`sumPrice`cnt]+:(p;1); .rte2.buckets[s],:enlist `bucket`sumPrice`cnt!(b;p;1)]};

.rte2.computeAnalytics:{[s;lastPrice;now] buckets:.rte2.buckets[s]; n:exec sum cnt from buckets; sumP:exec sum sumPrice from buckets; avgPrice:$[n > 0; sumP % n; 0n]; actualStart:$[0 < count buckets; exec min bucket from buckets; now]; coverageNs:now - actualStart; fillPct:1.0 & coverageNs % .rte2.cfg.windowNs; isValid:fillPct >= .rte2.cfg.validityThreshold; `rollAnalytics2 upsert (s; lastPrice; avgPrice; n; isValid; fillPct; actualStart; now)};

.u.upd:{[tbl;data] time:data 0; s:data 1; price:data 3; now:.z.p; if[not s in key .rte2.buckets; .rte2.initBuckets[s]]; .rte2.evict[s;now]; .rte2.addTrade[s;time;price]; .rte2.computeAnalytics[s;price;now]};

.rte2.connect:{[] -1 "Connecting to TP..."; h:@[hopen; `$"::",string .rte2.cfg.tpPort; {-1 "Failed: ",x; 0N}]; if[null h; '"Cannot connect"]; res:h (`.u.sub; `trade_binance; `); -1 "Subscribed"; .rte2.tpHandle:h};

system "p ",string .rte2.cfg.port;
-1 "RTE2 on port ",string[.rte2.cfg.port];
-1 "Mode: ",$[.rte2.cfg.standalone; "standalone"; "live"];
if[not .rte2.cfg.standalone; .rte2.connect[]];
-1 "Ready";
