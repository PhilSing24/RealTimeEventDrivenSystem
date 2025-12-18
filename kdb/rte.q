/ -------------------------------------------------------
/ rte.q
/ Real-Time Engine: Rolling analytics computation
/ -------------------------------------------------------

/ -------------------------------------------------------
/ Configuration
/ -------------------------------------------------------

.rte.cfg.port:5012;                      / RTE port
.rte.cfg.tpHost:`localhost;              / Tickerplant host
.rte.cfg.tpPort:5010;                    / Tickerplant port
.rte.cfg.windowNs:5 * 60 * 1000000000j;  / Rolling window: 5 minutes in ns
.rte.cfg.validityThreshold:0.5;          / Window must be 50% filled to be valid

/ -------------------------------------------------------
/ Rolling Window State (per symbol)
/ -------------------------------------------------------

/ Buffer: stores recent trades within window
/ Dictionary mapping symbol -> (times list; prices list)
.rte.buffer:(`symbol$())!();

/ -------------------------------------------------------
/ Analytics Output (queryable state)
/ -------------------------------------------------------

rollAnalytics:([sym:`u#`symbol$()] 
  lastPrice:`float$();
  avgPrice5m:`float$();
  tradeCount5m:`long$();
  isValid:`boolean$();
  fillPct:`float$();
  windowStart:`timestamp$();
  updateTime:`timestamp$()
  );

/ -------------------------------------------------------
/ Core Functions
/ -------------------------------------------------------

/ Initialize buffer for a symbol (empty lists)
.rte.initBuffer:{[s]
  .rte.buffer[s]:`times`prices!(0#.z.p; 0#0f);
  };

/ Evict old entries from a symbol's buffer
.rte.evict:{[s;now]
  cutoff:now - .rte.cfg.windowNs;
  buf:.rte.buffer[s];
  times:buf`times;
  prices:buf`prices;
  if[0 = count times; :()];
  mask:times >= cutoff;
  .rte.buffer[s]:`times`prices!((times where mask); (prices where mask));
  };

/ Add trade to buffer
.rte.addTrade:{[s;time;price]
  buf:.rte.buffer[s];
  times:buf`times;
  prices:buf`prices;
  .rte.buffer[s]:`times`prices!((times,time); (prices,price));
  };

/ Compute analytics for a symbol
.rte.computeAnalytics:{[s;lastPrice;now]
  buf:.rte.buffer[s];
  times:buf`times;
  prices:buf`prices;
  n:count times;
  
  / Compute fill percentage (how much of window has data)
  windowStart:now - .rte.cfg.windowNs;
  actualStart:$[n > 0; min times; now];
  coverageNs:now - actualStart;
  fillPct:coverageNs % .rte.cfg.windowNs;
  fillPct:1.0 & fillPct;  / Cap at 100%
  
  / Validity: window must be sufficiently filled
  isValid:fillPct >= .rte.cfg.validityThreshold;
  
  / Analytics
  avgPrice:$[n > 0; avg prices; 0n];
  
  / Update output table
  `rollAnalytics upsert (s; lastPrice; avgPrice; n; isValid; fillPct; actualStart; now);
  };

/ -------------------------------------------------------
/ Update Handler (called by TP via pub/sub)
/ -------------------------------------------------------

.u.upd:{[tbl;data]
  / Extract fields from incoming trade
  / Schema: time, sym, tradeId, price, qty, buyerIsMaker, exchEventTimeMs, exchTradeTimeMs, 
  /         fhRecvTimeUtcNs, fhParseUs, fhSendUs, fhSeqNo, tpRecvTimeUtcNs
  time:data 0;
  s:data 1;
  price:data 3;
  
  / Current time for eviction
  now:.z.p;
  
  / Initialize buffer for new symbol if needed
  if[not s in key .rte.buffer; .rte.initBuffer[s]];
  
  / Evict old entries
  .rte.evict[s;now];
  
  / Add new trade
  .rte.addTrade[s;time;price];
  
  / Recompute analytics
  .rte.computeAnalytics[s;price;now];
  };

/ -------------------------------------------------------
/ Subscription to Tickerplant
/ -------------------------------------------------------

.rte.connect:{[]
  addr:`$":",string[.rte.cfg.tpHost],":",string[.rte.cfg.tpPort];
  -1 "Connecting to tickerplant on port ",string[.rte.cfg.tpPort],"...";
  h:@[hopen; addr; {-1 "Failed to connect to TP: ",x; 0N}];
  if[null h; '"Cannot connect to tickerplant"];
  
  / Subscribe to trade_binance table
  res:h (`.u.sub; `trade_binance; `);
  -1 "Subscribed to: ", string first res;
  
  .rte.tpHandle:h;
  };

/ -------------------------------------------------------
/ Startup
/ -------------------------------------------------------

system "p ",string .rte.cfg.port;

-1 "RTE starting on port ",string[.rte.cfg.port];
-1 "Window size: ",string[.rte.cfg.windowNs div 1000000000]," seconds";

/ Connect and subscribe to TP
.rte.connect[];

-1 "RTE ready - tick-by-tick analytics enabled";

/ -------------------------------------------------------
/ End
/ -------------------------------------------------------
