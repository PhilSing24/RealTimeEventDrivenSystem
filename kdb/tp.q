/ =============================================================================
/ tp.q - Tickerplant
/ =============================================================================
/
/ Purpose:
/   Central pub/sub hub for real-time data distribution.
/   Receives trades from Feed Handler, adds timestamp, fans out to subscribers.
/
/ Architecture role:
/   FH → [Tickerplant] → RDB (storage)
/                      → RTE (analytics)
/
/ Key responsibilities:
/   - Receive trade events from feed handler
/   - Capture TP receive timestamp (tpRecvTimeUtcNs)
/   - Manage subscriber connections (RDB, RTE)
/   - Fan-out updates to all subscribers
/   - Handle subscriber disconnect gracefully
/
/ Design decisions:
/   - No logging/persistence (ADR-003: ephemeral, latency-focused)
/   - Async pub to subscribers (neg[h]) to avoid blocking
/   - Single-threaded (standard kdb+ model)
/
/ @see docs/decisions/adr-002-Feed-handler-to-kdb-ingestion-path.md
/ @see docs/decisions/adr-003-Tickerplant-Logging-and-Durability-Strategy.md
/ =============================================================================

/ -----------------------------------------------------------------------------
/ Configuration
/ -----------------------------------------------------------------------------

/ Epoch offset: nanoseconds between kdb+ epoch (2000.01.01) and Unix (1970.01.01)
/ Used to convert .z.p (kdb timestamp) to Unix nanoseconds for cross-system correlation
.u.epochOffset:946684800000000000j;

/ -----------------------------------------------------------------------------
/ Table Schema
/ -----------------------------------------------------------------------------
/ Defines the structure for incoming trades.
/ This table holds data briefly before publishing to subscribers.
/ 13 fields - TP does not add rdbApplyTimeUtcNs (RDB adds that)
/
/ Field descriptions:
/   time             - FH receive time converted to kdb timestamp (for time-based queries)
/   sym              - Trading symbol (BTCUSDT, ETHUSDT)
/   tradeId          - Binance trade ID (unique per symbol)
/   price            - Trade price
/   qty              - Trade quantity
/   buyerIsMaker     - True if buyer was the maker (passive side)
/   exchEventTimeMs  - Binance server event time (ms since Unix epoch)
/   exchTradeTimeMs  - Binance trade execution time (ms since Unix epoch)
/   fhRecvTimeUtcNs  - Feed handler receive time (ns since Unix epoch)
/   fhParseUs        - FH JSON parse/normalize duration (microseconds)
/   fhSendUs         - FH IPC send preparation duration (microseconds)
/   fhSeqNo          - FH sequence number (for gap detection)
/   tpRecvTimeUtcNs  - TP receive time (ns since Unix epoch) - ADDED BY TP

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

/ -----------------------------------------------------------------------------
/ Pub/Sub Infrastructure
/ -----------------------------------------------------------------------------

/ Subscriber registry: maps table name -> list of subscriber handles
/ When a downstream process (RDB, RTE) subscribes, its handle is added here
/ Example after RDB and RTE connect: (,`trade_binance)!,(5 6i)
.u.w:enlist[`trade_binance]!enlist `int$();

/ Subscribe function
/ Called by downstream processes (RDB, RTE) to register for updates
/ @param tbl - Table name to subscribe to (e.g., `trade_binance)
/ @param syms - Symbol filter (` for all symbols) - not used in this implementation
/ @return Tuple of (table name; current table schema)
.u.sub:{[tbl;syms]
  / Validate table exists
  if[not tbl in key .u.w; '"unknown table: ",string tbl];
  
  / Add caller's handle (.z.w) to subscriber list for this table
  / Note: .z.w is the handle of the process that called this function
  .u.w[tbl],::.z.w;
  
  / Return table name and empty schema (subscriber can use to initialize)
  (tbl; value tbl)
  };

/ Publish updates to all subscribers of a table
/ Uses async send (neg[h]) to avoid blocking if subscriber is slow
/ @param tbl - Table name
/ @param data - Row data to publish
.u.pub:{[tbl;data]
  / For each subscriber handle, send the update asynchronously
  / neg[h] makes it async (fire-and-forget)
  / Sends: (`.u.upd; `trade_binance; data) to each subscriber
  {[h;tbl;data] neg[h] (`.u.upd; tbl; data)} [;tbl;data] each .u.w[tbl];
  };

/ Handle subscriber disconnect
/ Called automatically by kdb+ when a connection closes
/ Removes disconnected handle from all subscriber lists
/ @param h - Handle of disconnected process
.z.pc:{[h]
  / Remove handle h from all subscriber lists
  .u.w:{x except h} each .u.w;
  };

/ -----------------------------------------------------------------------------
/ Update Handling
/ -----------------------------------------------------------------------------

/ Convert kdb+ timestamp to nanoseconds since Unix epoch
/ @param ts - kdb+ timestamp (e.g., .z.p)
/ @return Nanoseconds since 1970.01.01 (Unix epoch)
.u.tsToNs:{[ts]
  .u.epochOffset + "j"$ts - 2000.01.01D0
  };

/ Core update function - entry point for incoming trades
/ Called by feed handler via async IPC: k(-tp, ".u.upd", ...)
/
/ Processing steps:
/   1. Capture TP receive timestamp (latency measurement point)
/   2. Append timestamp to incoming row
/   3. Insert into local table
/   4. Publish to all subscribers
/
/ @param tbl - Table name (always `trade_binance in this system)
/ @param data - Row data as a list (12 fields from FH)
.u.upd:{[tbl;data]
  / Step 1: Capture TP receive time immediately
  / This is a critical measurement point for latency analysis
  tpRecvTs:.z.p;
  tpRecvTimeUtcNs:.u.tsToNs[tpRecvTs];
  
  / Step 2: Append tpRecvTimeUtcNs to the row
  / Data arrives as 12-element list, becomes 13 elements
  data:data,tpRecvTimeUtcNs;
  
  / Step 3: Insert into local table
  / This is optional (TP doesn't need to store) but useful for debugging
  tbl insert data;
  
  / Step 4: Publish to all subscribers (RDB, RTE)
  / Async publish to avoid blocking if subscribers are slow
  .u.pub[tbl;data];
  };

/ -----------------------------------------------------------------------------
/ Startup
/ -----------------------------------------------------------------------------

/ Set listening port
\p 5010

/ Startup messages
-1 "Tickerplant started on port 5010";
-1 "Subscribers: ", .Q.s1 .u.w;

/ -----------------------------------------------------------------------------
/ End
/ -----------------------------------------------------------------------------
