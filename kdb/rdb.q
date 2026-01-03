/ rdb.q - Real-Time Database
/ Updated for L5 quotes (28 fields)

/ -----------------------------------------------------------------------------
/ Configuration
/ -----------------------------------------------------------------------------

/ Epoch offset: nanoseconds between 2000.01.01 and 1970.01.01
.rdb.epochOffset:946684800000000000j;

/ -----------------------------------------------------------------------------
/ Table Schema
/ -----------------------------------------------------------------------------

/ Trade table - 14 fields (includes rdbApplyTimeUtcNs)
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

/ Quote table - L5 depth (28 fields: includes rdbApplyTimeUtcNs)
quote_binance:([]
  time:`timestamp$();
  sym:`symbol$();
  / L5 bid prices (best to worst)
  bidPrice1:`float$();
  bidPrice2:`float$();
  bidPrice3:`float$();
  bidPrice4:`float$();
  bidPrice5:`float$();
  / L5 bid quantities
  bidQty1:`float$();
  bidQty2:`float$();
  bidQty3:`float$();
  bidQty4:`float$();
  bidQty5:`float$();
  / L5 ask prices (best to worst)
  askPrice1:`float$();
  askPrice2:`float$();
  askPrice3:`float$();
  askPrice4:`float$();
  askPrice5:`float$();
  / L5 ask quantities
  askQty1:`float$();
  askQty2:`float$();
  askQty3:`float$();
  askQty4:`float$();
  askQty5:`float$();
  / Metadata
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

-1 "Tables:";
-1 "  trade_binance: ",string[count cols trade_binance]," fields";
-1 "  quote_binance: ",string[count cols quote_binance]," fields (L5)";
-1 "  health_feed_handler: ",string[count cols health_feed_handler]," fields";

-1 "";
-1 "RDB ready";

/ -----------------------------------------------------------------------------
/ End
/ -----------------------------------------------------------------------------
