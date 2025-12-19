/ rte.q - Real-Time Engine (rolling analytics)

/ Configuration
.rte.cfg.port:5012;
.rte.cfg.tpPort:5010;
.rte.cfg.windowNs:5 * 60 * 1000000000j;
.rte.cfg.validityThreshold:0.5;

/ Buffer: symbol -> (times; prices)
.rte.buffer:(`symbol$())!();

/ Analytics output table
rollAnalytics:([sym:`u#`symbol$()] 
  lastPrice:`float$();
  avgPrice5m:`float$();
  tradeCount5m:`long$();
  isValid:`boolean$();
  fillPct:`float$();
  windowStart:`timestamp$();
  updateTime:`timestamp$()
  );

.rte.initBuffer:{[s]
  .rte.buffer[s]:`times`prices!(0#.z.p; 0#0f);
  };

.rte.evict:{[s;now]
  cutoff:now - .rte.cfg.windowNs;
  buf:.rte.buffer[s];
  times:buf`times;
  prices:buf`prices;
  if[0 = count times; :()];
  mask:times >= cutoff;
  .rte.buffer[s]:`times`prices!((times where mask); (prices where mask));
  };

.rte.addTrade:{[s;time;price]
  buf:.rte.buffer[s];
  .rte.buffer[s]:`times`prices!((buf[`times],time); (buf[`prices],price));
  };

.rte.computeAnalytics:{[s;lastPrice;now]
  buf:.rte.buffer[s];
  times:buf`times;
  prices:buf`prices;
  n:count times;
  
  actualStart:$[n > 0; min times; now];
  coverageNs:now - actualStart;
  fillPct:1.0 & coverageNs % .rte.cfg.windowNs;
  isValid:fillPct >= .rte.cfg.validityThreshold;
  avgPrice:$[n > 0; avg prices; 0n];
  
  `rollAnalytics upsert (s; lastPrice; avgPrice; n; isValid; fillPct; actualStart; now);
  };

.u.upd:{[tbl;data]
  time:data 0;
  s:data 1;
  price:data 3;
  now:.z.p;
  
  if[not s in key .rte.buffer; .rte.initBuffer[s]];
  .rte.evict[s;now];
  .rte.addTrade[s;time;price];
  .rte.computeAnalytics[s;price;now];
  };

.rte.connect:{[]
  -1 "Connecting to tickerplant on port ",string[.rte.cfg.tpPort],"...";
  h:@[hopen; `$"::",string .rte.cfg.tpPort; {-1 "Failed to connect to TP: ",x; 0N}];
  if[null h; '"Cannot connect to tickerplant"];
  res:h (`.u.sub; `trade_binance; `);
  -1 "Subscribed to: ", string first res;
  .rte.tpHandle:h;
  };

\p 5012
-1 "RTE starting on port 5012";
-1 "Window: ",string[.rte.cfg.windowNs div 1000000000],"s | Validity: ",string[100 * .rte.cfg.validityThreshold],"%";
.rte.connect[];
-1 "RTE ready - tick-by-tick analytics";
