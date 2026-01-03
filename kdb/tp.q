/ tp.q
/ Tickerplant with pub-sub, timestamp capture, and logging
/ Updated for L5 quotes (27 fields)

/ -------------------------------------------------------
/ Configuration
/ -------------------------------------------------------

.tp.cfg.port:5010;
.tp.cfg.logDir:"logs";
.tp.cfg.logEnabled:1b;

/ Epoch offset: nanoseconds between 2000.01.01 and 1970.01.01
.tp.epochOffset:946684800000000000j;

/ -------------------------------------------------------
/ Table schema
/ -------------------------------------------------------

/ Trade table - 13 fields (TP adds tpRecvTimeUtcNs, RDB adds rdbApplyTimeUtcNs)
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

/ Quote table - L5 depth (27 fields: 22 price/qty + 5 meta + tpRecvTimeUtcNs)
/ FH sends 26 fields, TP adds tpRecvTimeUtcNs
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
  tpRecvTimeUtcNs:`long$()
  );

/ Health metrics from feed handlers (no tpRecvTimeUtcNs added)
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

/ -------------------------------------------------------
/ Logging - Separate files for trades and quotes
/ -------------------------------------------------------

/ Log handles (set at startup)
.tp.tradeLogHandle:0N;
.tp.quoteLogHandle:0N;

/ Build log file path for today
/ @param typ - `trade or `quote
.tp.logFile:{[typ]
  hsym `$(.tp.cfg.logDir,"/",string[.z.D],".",string[typ],".log")
  };

/ Open log files
.tp.openLog:{[]
  if[not .tp.cfg.logEnabled; :()];
  system "mkdir -p ",.tp.cfg.logDir;
  .tp.tradeLogHandle:hopen .tp.logFile[`trade];
  .tp.quoteLogHandle:hopen .tp.logFile[`quote];
  -1 "Trade log opened: ",string .tp.logFile[`trade];
  -1 "Quote log opened: ",string .tp.logFile[`quote];
  };

/ Close log files
.tp.closeLog:{[]
  if[not .tp.cfg.logEnabled; :()];
  if[not null .tp.tradeLogHandle; hclose .tp.tradeLogHandle];
  if[not null .tp.quoteLogHandle; hclose .tp.quoteLogHandle];
  };

/ Write to appropriate log
.tp.log:{[tbl;data]
  if[not .tp.cfg.logEnabled; :()];
  $[tbl = `trade_binance;
    .tp.tradeLogHandle enlist (`.u.upd; tbl; data);
    tbl = `quote_binance;
    .tp.quoteLogHandle enlist (`.u.upd; tbl; data);
    ()  / health_feed_handler - not logged
  ];
  };

/ Rotate logs (call at end of day)
.tp.rotate:{[]
  .tp.closeLog[];
  .tp.openLog[];
  };

/ -------------------------------------------------------
/ Pub/Sub Infrastructure (.u namespace - kdb+ convention)
/ -------------------------------------------------------

/ Subscriber dictionary: table -> list of handles
.u.w:`trade_binance`quote_binance`health_feed_handler!3#enlist `int$();

/ Subscribe function
/ Called by downstream processes (RDB, RTE)
/ Returns: (table name; current schema; log file path; log message count)
.u.sub:{[tbl;syms]
  if[not tbl in key .u.w; '"unknown table: ",string tbl];
  .u.w[tbl],::.z.w;
  logFile:$[tbl = `trade_binance; .tp.logFile[`trade];
            tbl = `quote_binance; .tp.logFile[`quote];
            `];
  (tbl; value tbl; logFile; count value tbl)
  };

/ Publish to all subscribers of a table
.u.pub:{[tbl;data]
  {[h;tbl;data] neg[h] (`.u.upd; tbl; data)} [;tbl;data] each .u.w[tbl];
  };

/ Handle subscriber disconnect
.z.pc:{[h]
  .u.w:{x except h} each .u.w;
  };

/ -------------------------------------------------------
/ Update handling
/ -------------------------------------------------------

/ Convert kdb timestamp to nanoseconds since Unix epoch
.tp.tsToNs:{[ts]
  .tp.epochOffset + "j"$ts - 2000.01.01D0
  };

/ Core update function
/ Called by feed handler via .z.ps -> .u.upd
.u.upd:{[tbl;data]
  / Health updates don't get tpRecvTimeUtcNs added
  if[tbl = `health_feed_handler;
    tbl insert data;
    .u.pub[tbl;data];
    :();
  ];
  
  / Market data updates get TP timestamp
  / Capture TP receive time
  tpRecvTs:.z.p;
  tpRecvTimeUtcNs:.tp.tsToNs[tpRecvTs];
  
  / Add tpRecvTimeUtcNs to the row
  / data arrives as a list (single row) - append the new field
  data:data,tpRecvTimeUtcNs;
  
  / Log to disk
  .tp.log[tbl;data];
  
  / Insert locally
  tbl insert data;
  
  / Publish to subscribers
  .u.pub[tbl;data];
  };

/ -------------------------------------------------------
/ Startup
/ -------------------------------------------------------

system "p ",string .tp.cfg.port;

-1 "TP starting on port ",string[.tp.cfg.port];
-1 "Logging: ",$[.tp.cfg.logEnabled; "enabled"; "disabled"];

/ Open log files
.tp.openLog[];

-1 "Tables:";
-1 "  trade_binance: ",string[count cols trade_binance]," fields";
-1 "  quote_binance: ",string[count cols quote_binance]," fields (L5)";
-1 "  health_feed_handler: ",string[count cols health_feed_handler]," fields";

/ -------------------------------------------------------
/ End
/ -------------------------------------------------------
