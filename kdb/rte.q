/ rte.q - Real-Time Engine
/ VWAP (trades) + Imbalance (quotes)

.rte.cfg.port:5012;
.rte.cfg.tpPort:5010;
.rte.cfg.defaultWindowNs:5 * 60 * 1000000000j;

/ =============================================================================
/ VWAP State - using lists instead of table
/ =============================================================================

.rte.vwap.buf:()!();

.rte.vwap.init:{[s]
  .rte.vwap.buf[s]:`times`prices`qtys`pxqtys!(0#.z.p; 0#0f; 0#0f; 0#0f);
  };

.rte.vwap.add:{[s;t;p;q]
  if[not s in key .rte.vwap.buf; .rte.vwap.init[s]];
  b:.rte.vwap.buf[s];
  .rte.vwap.buf[s]:`times`prices`qtys`pxqtys!(b[`times],t; b[`prices],p; b[`qtys],q; b[`pxqtys],p*q);
  };

.rte.vwap.evict:{[s;cutoff]
  b:.rte.vwap.buf[s];
  mask:b[`times] >= cutoff;
  .rte.vwap.buf[s]:`times`prices`qtys`pxqtys!(b[`times] where mask; b[`prices] where mask; b[`qtys] where mask; b[`pxqtys] where mask);
  };

.rte.vwap.calc:{[s;windowNs]
  if[not s in key .rte.vwap.buf; 
    :(`sym`vwap`totalQty`tradeCount`isValid)!(s; 0n; 0f; 0j; 0b)];
  now:.z.p;
  .rte.vwap.evict[s; now - windowNs];
  b:.rte.vwap.buf[s];
  n:count b`times;
  if[n = 0; :(`sym`vwap`totalQty`tradeCount`isValid)!(s; 0n; 0f; 0j; 0b)];
  totalQty:sum b`qtys;
  vwap:$[totalQty > 0; (sum b`pxqtys) % totalQty; 0n];
  (`sym`vwap`totalQty`tradeCount`isValid)!(s; vwap; totalQty; n; n > 10)
  };

/ =============================================================================
/ Imbalance State - L5
/ =============================================================================

.rte.imb.latest:()!();

.rte.imb.update:{[s;bidDepth;askDepth;t]
  total:bidDepth + askDepth;
  imb:$[total > 0f; (bidDepth - askDepth) % total; 0n];
  .rte.imb.latest[s]:`bidDepth`askDepth`imbalance`time!(bidDepth; askDepth; imb; t);
  };

/ =============================================================================
/ Query Interface
/ =============================================================================

.rte.getVwap:{[s;mins]
  windowNs:60000000000 * `long$mins;
  .rte.vwap.calc[s; windowNs]
  };

.rte.getImbalance:{[s]
  $[s in key .rte.imb.latest; .rte.imb.latest[s]; `bidDepth`askDepth`imbalance`time!(0n;0n;0n;0Np)]
  };

.rte.getAllVwap:{[]
  syms:key .rte.vwap.buf;
  if[0 = count syms; :()];
  .rte.vwap.calc[;.rte.cfg.defaultWindowNs] each syms
  };

.rte.getAllImbalance:{[] .rte.imb.latest };

/ =============================================================================
/ Update Handler
/ =============================================================================

.u.upd:{[tbl;data]
  if[tbl = `trade_binance;
    .rte.vwap.add[data 1; data 0; data 3; data 4];
  ];
  if[tbl = `quote_binance;
    s:data 1;
    t:data 0;
    bidDepth:(data 7)+(data 8)+(data 9)+(data 10)+(data 11);
    askDepth:(data 17)+(data 18)+(data 19)+(data 20)+(data 21);
    .rte.imb.update[s; bidDepth; askDepth; t];
  ];
  };

/ =============================================================================
/ Subscription
/ =============================================================================

.rte.connect:{[]
  -1 "Connecting to TP...";
  h:@[hopen; `$"::",string .rte.cfg.tpPort; {-1 "Failed: ",x; 0N}];
  if[null h; '"Cannot connect to TP"];
  h (`.u.sub; `trade_binance; `);
  -1 "Subscribed to trades";
  h (`.u.sub; `quote_binance; `);
  -1 "Subscribed to quotes";
  .rte.tpHandle:h;
  };

system "p ",string .rte.cfg.port;
-1 "RTE starting on port ",string .rte.cfg.port;
.rte.connect[];
-1 "";
-1 "Queries:";
-1 "  .rte.getVwap[`BTCUSDT;5]   / 5-min VWAP";
-1 "  .rte.getVwap[`BTCUSDT;1]   / 1-min VWAP";
-1 "  .rte.getImbalance[`BTCUSDT]";
-1 "  .rte.getAllVwap[]";
-1 "  .rte.getAllImbalance[]";
-1 "";
-1 "RTE ready";
