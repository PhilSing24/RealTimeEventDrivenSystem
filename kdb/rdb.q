
/ rdb.q - Real-Time Database

/ -----------------------------------------------------------------------------
/ Configuration
/ -----------------------------------------------------------------------------

/ Epoch offset: nanoseconds between 2000.01.01 and 1970.01.01
.rdb.epochOffset:946684800000000000j;

/ -----------------------------------------------------------------------------
/ Table Schema (14 fields - includes rdbApplyTimeUtcNs)
/ -----------------------------------------------------------------------------


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

quote_binance:([]
  time:`timestamp$();
  sym:`symbol$();
  bidPrice:`float$();
  bidQty:`float$();
  askPrice:`float$();
  askQty:`float$();
  isValid:`boolean$();
  exchEventTimeMs:`long$();
  fhRecvTimeUtcNs:`long$();
  fhSeqNo:`long$();
  tpRecvTimeUtcNs:`long$();
  rdbApplyTimeUtcNs:`long$()
  );

/ Health metrics from feed handlers (no rdbApplyTimeUtcNs added)
health_feed_handler:([]
  time:`timestamp$();
  handler:`symbol$();            / `trade_fh or `quote_fh
  startTimeUtc:`timestamp$();    / When FH started
  uptimeSec:`long$();            / Seconds since start
  msgsReceived:`long$();         / Total messages from Binance
  msgsPublished:`long$();        / Total messages sent to TP
  lastMsgTimeUtc:`timestamp$();  / Time of last received message
  lastPubTimeUtc:`timestamp$();  / Time of last publish to TP
  connState:`symbol$();          / `connected, `reconnecting, `disconnected
  symbolCount:`int$()            / Number of symbols subscribed
  );

/ -----------------------------------------------------------------------------
/ Utility Functions
/ -----------------------------------------------------------------------------

/ Convert kdb timestamp to nanoseconds since Unix epoch
.rdb.tsToNs:{[ts]
  .rdb.epochOffset + "j"$ts - 2000.01.01D0
  };

/ -----------------------------------------------------------------------------
/ Update Handler (called by TP via pub/sub)
/ -----------------------------------------------------------------------------

.u.upd:{[tbl;data]
  / Health updates don't get rdbApplyTimeUtcNs added
  if[tbl = `health_feed_handler;
    tbl insert data;
    :();
  ];
  
  / Market data updates get RDB timestamp
  / Capture RDB apply time immediately
  rdbApplyTs:.z.p;
  rdbApplyTimeUtcNs:.rdb.tsToNs[rdbApplyTs];
  
  / Append rdbApplyTimeUtcNs to the row
  data:data,rdbApplyTimeUtcNs;
  
  / Insert into table
  tbl insert data;
  };

/ -----------------------------------------------------------------------------
/ Subscription to Tickerplant
/ -----------------------------------------------------------------------------

.rdb.connect:{[]
  -1 "Connecting to tickerplant on port 5010...";
  h:@[hopen; `::5010; {-1 "Failed to connect to TP: ",x; 0N}];
  if[null h; '"Cannot connect to tickerplant"];
  
  / Subscribe to all tables
  res:h (`.u.sub; `trade_binance; `);
  -1 "Subscribed to: ", string first res;
  
  res:h (`.u.sub; `quote_binance; `);
  -1 "Subscribed to: ", string first res;
  
  res:h (`.u.sub; `health_feed_handler; `);
  -1 "Subscribed to: ", string first res;
  
  / Store handle
  .rdb.tpHandle:h;
  };

/ -----------------------------------------------------------------------------
/ Startup
/ -----------------------------------------------------------------------------

\p 5011

-1 "RDB starting on port 5011";

/ Connect and subscribe to TP
.rdb.connect[];

-1 "RDB ready - storage only (telemetry via TEL process)";

/ -----------------------------------------------------------------------------
/ End
/ -----------------------------------------------------------------------------
