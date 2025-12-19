/ -------------------------------------------------------
/ tp.q
/ Tickerplant with pub/sub and timestamp capture
/ -------------------------------------------------------

/ -------------------------------------------------------
/ Configuration
/ -------------------------------------------------------

/ Epoch offset: nanoseconds between 2000.01.01 and 1970.01.01
.u.epochOffset:946684800000000000j;

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

/ -------------------------------------------------------
/ Pub/Sub Infrastructure
/ -------------------------------------------------------

/ Subscriber dictionary: table -> list of handles
.u.w:enlist[`trade_binance]!enlist `int$();

/ Subscribe function
/ Called by downstream processes (RDB, RTE)
/ Returns: (table name; current schema)
.u.sub:{[tbl;syms]
  if[not tbl in key .u.w; '"unknown table: ",string tbl];
  .u.w[tbl],::.z.w;
  (tbl; value tbl)
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
.u.tsToNs:{[ts]
  .u.epochOffset + "j"$ts - 2000.01.01D0
  };

/ Core update function
/ Called by feed handler via .z.ps -> .u.upd
.u.upd:{[tbl;data]
  / Capture TP receive time
  tpRecvTs:.z.p;
  tpRecvTimeUtcNs:.u.tsToNs[tpRecvTs];
  
  / Add tpRecvTimeUtcNs to the row
  / data arrives as a list (single row) - append the new field
  data:data,tpRecvTimeUtcNs;
  
  / Insert locally
  tbl insert data;
  
  / Publish to subscribers
  .u.pub[tbl;data];
  };

/ -------------------------------------------------------
/ Startup
/ -------------------------------------------------------

\p 5010

-1 "Tickerplant started on port 5010";
-1 "Subscribers: ", .Q.s1 .u.w;

/ -------------------------------------------------------
/ End
/ -------------------------------------------------------
