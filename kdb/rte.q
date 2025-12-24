/ rte.q - Real-Time Engine (rolling analytics)
/ Usage: q rte.q -standalone   (for replay testing)

.rte.cfg.port:5012;
.rte.cfg.tpPort:5010;
.rte.cfg.windowNs:5 * 60 * 1000000000j;
.rte.cfg.validityThreshold:0.5;
.rte.cfg.standalone:0b;

args:.Q.opt .z.x;
if[`standalone in key args; .rte.cfg.standalone:1b];

.rte.buffer:(`symbol$())!();
.rte.lastComputeUs:0j;

rollAnalytics:([sym:`u#`symbol$()] lastPrice:`float$(); avgPrice5m:`float$(); tradeCount5m:`long$(); isValid:`boolean$(); fillPct:`float$(); windowStart:`timestamp$(); updateTime:`timestamp$());

.rte.initBuffer:{[s] .rte.buffer[s]:`times`prices!(0#.z.p; 0#0f)};

.rte.evict:{[s;now] cutoff:now - .rte.cfg.windowNs; buf:.rte.buffer[s]; times:buf`times; prices:buf`prices; if[0 = count times; :()]; mask:times >= cutoff; .rte.buffer[s]:`times`prices!((times where mask); (prices where mask))};

.rte.addTrade:{[s;time;price] buf:.rte.buffer[s]; .rte.buffer[s]:`times`prices!((buf[`times],time); (buf[`prices],price))};

.rte.computeAnalytics:{[s;lastPrice;now] buf:.rte.buffer[s]; times:buf`times; prices:buf`prices; n:count times; actualStart:$[n > 0; min times; now]; coverageNs:now - actualStart; fillPct:1.0 & coverageNs % .rte.cfg.windowNs; isValid:fillPct >= .rte.cfg.validityThreshold; avgPrice:$[n > 0; avg prices; 0n]; `rollAnalytics upsert (s; lastPrice; avgPrice; n; isValid; fillPct; actualStart; now)};

.u.upd:{[tbl;data] start:.z.p; time:data 0; s:data 1; price:data 3; now:.z.p; if[not s in key .rte.buffer; .rte.initBuffer[s]]; .rte.evict[s;now]; .rte.addTrade[s;time;price]; .rte.computeAnalytics[s;price;now]; .rte.lastComputeUs:`long$(.z.p - start) % 1000};

.rte.connect:{[] -1 "Connecting to tickerplant..."; h:@[hopen; `$"::",string .rte.cfg.tpPort; {-1 "Failed: ",x; 0N}]; if[null h; '"Cannot connect"]; res:h (`.u.sub; `trade_binance; `); -1 "Subscribed"; .rte.tpHandle:h};

system "p ",string .rte.cfg.port;
-1 "RTE on port ",string[.rte.cfg.port];
-1 "Mode: ",$[.rte.cfg.standalone; "standalone"; "live"];
if[not .rte.cfg.standalone; .rte.connect[]];
-1 "Ready";
