/ tp.q
/ Tickerplant with pub-sub, timestamp capture, and logging

/ -------------------------------------------------------
/ Configuration
/ -------------------------------------------------------

.tp.cfg.port:5010;
.tp.cfg.logDir:"logs";
.tp.cfg.logEnabled:1b;

/ Epoch offset: nanoseconds between 2000.01.01 and 1970.01.01
.tp.epochOffset:946684800000000000j;

/ -------------------------------------------------------
/ Table schema (13 fields - TP does not know rdbApplyTimeUtcNs)
/ -------------------------------------------------------

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
/ Logging
/ -------------------------------------------------------

/ Build log file path for today
.tp.logFile:{
  hsym `$(.tp.cfg.logDir,"/",string[.z.D],".log")
  };

/ Open log file
.tp.openLog:{[]
  if[not .tp.cfg.logEnabled; :()];
  .tp.logHandle:hopen .tp.logFile[];
  -1 "Log file opened: ",string .tp.logFile[];
  };

/ Close log file
.tp.closeLog:{[]
  if[not .tp.cfg.logEnabled; :()];
  if[not null .tp.logHandle; hclose .tp.logHandle];
  };

/ Write to log
.tp.log:{[tbl;data]
  if[not .tp.cfg.logEnabled; :()];
  .tp.logHandle enlist (`.u.upd; tbl; data);
  };

/ Rotate log (call at end of day)
.tp.rotate:{[]
  .tp.closeLog[];
  .tp.openLog[];
  };

/ Log handle (set at startup)
.tp.logHandle:0N;

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
  (tbl; value tbl; .tp.logFile[]; count value tbl)
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

/ Open log file
.tp.openLog[];

-1 "Subscribers: ", .Q.s1 .u.w;

/ -------------------------------------------------------
/ End
/ -------------------------------------------------------
