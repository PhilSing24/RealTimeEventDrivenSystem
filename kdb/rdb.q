/ rdb.q - Real-Time Database (storage only)

/configuration

.rdb.cfg.port:5011;
.rdb.cfg.tpPort:5010;

.u.epochOffset:946684800000000000j;

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

.rdb.tsToNs:{[ts] .u.epochOffset + "j"$ts - 2000.01.01D0}; / Converts kdb+ timestamp to nanoseconds since Unix epoch (1970.01.01).

.u.upd:{[tbl;data]
  rdbApplyTimeUtcNs:.rdb.tsToNs[.z.p];
  data:data,rdbApplyTimeUtcNs;
  tbl insert data;
  };

.rdb.connect:{[]
  -1 "Connecting to tickerplant on port ",string[.rdb.cfg.tpPort],"...";
  addr:`$"::",string .rdb.cfg.tpPort;                                       / hopen expects a symbol 
  h:@[hopen; addr; {-1 "Failed to connect to TP: ",x; 0N}];                 / trapping using @
  if[null h; '"Cannot connect to tickerplant"];
  res:h (`.u.sub; `trade_binance; `);                                       / subscribe to all symbols
  -1 "Subscribed to: ", string first res;
  .rdb.tpHandle:h;                                                          / save handle for potential later use
  };

system "p ",string .rdb.cfg.port;
-1 "RDB starting on port ",string[.rdb.cfg.port];
.rdb.connect[];
-1 "RDB ready - storage only";
