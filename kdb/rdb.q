/ rdb.q - Real-Time Database (storage only)

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

.rdb.tsToNs:{[ts] .u.epochOffset + "j"$ts - 2000.01.01D0};

.u.upd:{[tbl;data]
  rdbApplyTimeUtcNs:.rdb.tsToNs[.z.p];
  data:data,rdbApplyTimeUtcNs;
  tbl insert data;
  };

.rdb.connect:{[]
  -1 "Connecting to tickerplant on port 5010...";
  h:@[hopen; `::5010; {-1 "Failed to connect to TP: ",x; 0N}];
  if[null h; '"Cannot connect to tickerplant"];
  res:h (`.u.sub; `trade_binance; `);
  -1 "Subscribed to: ", string first res;
  .rdb.tpHandle:h;
  };

\p 5011
-1 "RDB starting on port 5011";
.rdb.connect[];
-1 "RDB ready - storage only";
