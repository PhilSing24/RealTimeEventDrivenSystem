/ tp.q - Tickerplant

/ Configuration
.u.epochOffset:946684800000000000j;
.tp.cfg.logEnabled:1b;
.tp.cfg.logDir:"logs";

/ Trade table - 13 fields
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
  tpRecvTimeUtcNs:`long$()
  );

/ Quote table - 11 fields
quote_binance:([]
  time:`timestamp$();
  sym:`symbol$();
  bidPx:`float$();
  bidQty:`float$();
  askPx:`float$();
  askQty:`float$();
  isValid:`boolean$();
  exchEventTimeMs:`long$();
  fhRecvTimeUtcNs:`long$();
  fhSeqNo:`long$();
  tpRecvTimeUtcNs:`long$()
  );

/ Subscriber registry
.u.w:`trade_binance`quote_binance!(();())

/ Subscribe function
.u.sub:{[tbl;syms]
  if[not tbl in key .u.w; '"unknown table: ",string tbl];
  .u.w[tbl],::.z.w;
  (tbl; value tbl)
  };

/ Publish to subscribers
.u.pub:{[tbl;data]
  {[h;tbl;data] neg[h] (`.u.upd; tbl; data)}[;tbl;data] each .u.w[tbl];
  };

/ Handle subscriber disconnect
.z.pc:{[h]
  .u.w:{x except h} each .u.w;
  -1 "Subscriber disconnected: handle ",string h;
  };

/ Log file paths
.tp.tradeLogFile:{[] hsym `$(.tp.cfg.logDir),"/",string[.z.d],".trade.log"};
.tp.quoteLogFile:{[] hsym `$(.tp.cfg.logDir),"/",string[.z.d],".quote.log"};

/ Initialize log handles
.tp.initLog:{[]
  if[not .tp.cfg.logEnabled; :()];
  system "mkdir -p ",.tp.cfg.logDir;
  .tp.tradeLogHandle:hopen .tp.tradeLogFile[];
  .tp.quoteLogHandle:hopen .tp.quoteLogFile[];
  -1 "Trade log: ",1_string .tp.tradeLogFile[];
  -1 "Quote log: ",1_string .tp.quoteLogFile[];
  };

/ Log update to appropriate file
.tp.log:{[tbl;data]
  if[not .tp.cfg.logEnabled; :()];
  $[tbl = `trade_binance;
    .tp.tradeLogHandle enlist (`.u.upd; tbl; data);
    .tp.quoteLogHandle enlist (`.u.upd; tbl; data)
  ];
  };

/ Rotate logs
.tp.rotate:{[]
  if[not .tp.cfg.logEnabled; :()];
  @[hclose; .tp.tradeLogHandle; {}];
  @[hclose; .tp.quoteLogHandle; {}];
  .tp.tradeLogHandle:hopen .tp.tradeLogFile[];
  .tp.quoteLogHandle:hopen .tp.quoteLogFile[];
  -1 "Logs rotated";
  };

/ Convert timestamp to nanoseconds
.u.tsToNs:{[ts] .u.epochOffset + "j"$ts - 2000.01.01D0};

/ Update handler
.u.upd:{[tbl;data]
  tpRecvTs:.z.p;
  tpRecvTimeUtcNs:.u.tsToNs[tpRecvTs];
  data:data,tpRecvTimeUtcNs;
  .tp.log[tbl;data];
  tbl insert data;
  .u.pub[tbl;data];
  };

/ Startup
\p 5010
.tp.initLog[];
-1 "Tickerplant started on port 5010";
-1 "Tables: trade_binance, quote_binance";
-1 "Logging: ",$[.tp.cfg.logEnabled; "enabled"; "disabled"];