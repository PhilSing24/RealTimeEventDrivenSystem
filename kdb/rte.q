/ =============================================================================
/ rte.q - Real-Time Engine
/ =============================================================================
/
/ Purpose:
/   Computes rolling analytics (5-minute window) on live trade data.
/   Maintains per-symbol state, updates on every tick, exposes query interface.
/
/ Architecture role:
/   TP → [RTE] → Dashboards (queries)
/   
/   RTE is a peer to RDB, both subscribe directly to TP.
/   RTE focuses on analytics; RDB focuses on storage.
/
/ Key responsibilities:
/   - Receive trade events from TP (tick-by-tick)
/   - Maintain rolling window buffer per symbol
/   - Evict stale entries (older than window)
/   - Compute analytics: avgPrice5m, tradeCount5m
/   - Track validity (is window sufficiently filled?)
/   - Expose rollAnalytics table for dashboard queries
/
/ Design decisions:
/   - Tick-by-tick processing (no batching) for lowest latency
/   - Lazy eviction (evict on each update, not timer)
/   - 5-minute rolling window
/   - 50% fill threshold for validity
/   - Keyed table with `u# for O(1) symbol lookup
/
/ @see docs/decisions/adr-004-Real-Time-Rolling-Analytics-Computation.md
/ =============================================================================

/ -----------------------------------------------------------------------------
/ Configuration
/ -----------------------------------------------------------------------------

.rte.cfg.port:5012;                      / RTE listening port (for dashboard queries)
.rte.cfg.tpHost:`localhost;              / Tickerplant hostname
.rte.cfg.tpPort:5010;                    / Tickerplant port
.rte.cfg.windowNs:5 * 60 * 1000000000j;  / Rolling window size: 5 minutes in nanoseconds
.rte.cfg.validityThreshold:0.5;          / Window must be 50% filled to be considered valid

/ -----------------------------------------------------------------------------
/ Rolling Window State (per symbol)
/ -----------------------------------------------------------------------------

/ Buffer dictionary: symbol -> (times list; prices list)
/ Each symbol has its own buffer of recent trades within the window.
/
/ Structure example after receiving trades:
/   .rte.buffer = `BTCUSDT`ETHUSDT ! (
/     (`times`prices ! (timestamps; prices));
/     (`times`prices ! (timestamps; prices))
/   )
/
/ Why lists per symbol?
/   - Need to evict old entries (remove from head)
/   - Need to add new entries (append to tail)
/   - Simple and efficient for small symbol universe (2 symbols)
/
/ Trade-off: For 1000+ symbols, a different structure may be needed
.rte.buffer:(`symbol$())!();

/ -----------------------------------------------------------------------------
/ Analytics Output (queryable state)
/ -----------------------------------------------------------------------------

/ Main analytics table - queried by dashboards
/ Keyed by symbol with `u# attribute for O(1) lookup
/
/ Fields:
/   sym          - Symbol (key, unique)
/   lastPrice    - Most recent trade price
/   avgPrice5m   - Average price over rolling window
/   tradeCount5m - Number of trades in rolling window
/   isValid      - True if window has sufficient data (fillPct >= 50%)
/   fillPct      - Percentage of window duration covered by data
/   windowStart  - Timestamp of oldest trade in window
/   updateTime   - When analytics were last recomputed

rollAnalytics:([sym:`u#`symbol$()] 
  lastPrice:`float$();
  avgPrice5m:`float$();
  tradeCount5m:`long$();
  isValid:`boolean$();
  fillPct:`float$();
  windowStart:`timestamp$();
  updateTime:`timestamp$()
  );

/ -----------------------------------------------------------------------------
/ Core Functions
/ -----------------------------------------------------------------------------

/ Initialize buffer for a new symbol (empty lists)
/ Called when we see a symbol for the first time
/ @param s - Symbol to initialize
.rte.initBuffer:{[s]
  / Create empty lists with correct types
  / 0#.z.p creates empty timestamp list
  / 0#0f creates empty float list
  .rte.buffer[s]:`times`prices!(0#.z.p; 0#0f);
  };

/ Evict old entries from a symbol's buffer
/ Removes trades older than (now - windowSize)
/ Called before adding each new trade (lazy eviction)
/ @param s - Symbol to evict from
/ @param now - Current timestamp (for calculating cutoff)
.rte.evict:{[s;now]
  cutoff:now - .rte.cfg.windowNs;         / Oldest allowed timestamp
  buf:.rte.buffer[s];
  times:buf`times;
  prices:buf`prices;
  if[0 = count times; :()];               / Nothing to evict if empty
  mask:times >= cutoff;                   / Boolean mask: true = keep
  / Filter both lists using the mask
  .rte.buffer[s]:`times`prices!((times where mask); (prices where mask));
  };

/ Add a trade to a symbol's buffer
/ Appends timestamp and price to the respective lists
/ @param s - Symbol
/ @param time - Trade timestamp
/ @param price - Trade price
.rte.addTrade:{[s;time;price]
  buf:.rte.buffer[s];
  times:buf`times;
  prices:buf`prices;
  / Append to both lists (grow at tail)
  .rte.buffer[s]:`times`prices!((times,time); (prices,price));
  };

/ Compute analytics for a symbol and update output table
/ Called after every trade (tick-by-tick)
/ @param s - Symbol
/ @param lastPrice - Most recent trade price
/ @param now - Current timestamp
.rte.computeAnalytics:{[s;lastPrice;now]
  buf:.rte.buffer[s];
  times:buf`times;
  prices:buf`prices;
  n:count times;
  
  / ---- Compute fill percentage ----
  / How much of the window duration has data?
  / If trades span 3 minutes and window is 5 minutes, fillPct = 60%
  windowStart:now - .rte.cfg.windowNs;          / Theoretical window start
  actualStart:$[n > 0; min times; now];         / Actual oldest trade (or now if empty)
  coverageNs:now - actualStart;                  / Time span covered by data
  fillPct:coverageNs % .rte.cfg.windowNs;       / As percentage of window
  fillPct:1.0 & fillPct;                         / Cap at 100% (use & for min)
  
  / ---- Determine validity ----
  / Window is valid if we have enough data (>= 50% coverage)
  / This prevents showing misleading averages during startup or after gaps
  isValid:fillPct >= .rte.cfg.validityThreshold;
  
  / ---- Compute analytics ----
  avgPrice:$[n > 0; avg prices; 0n];            / Average price (null if no data)
  
  / ---- Update output table ----
  / Upsert: insert if new symbol, update if existing
  `rollAnalytics upsert (s; lastPrice; avgPrice; n; isValid; fillPct; actualStart; now);
  };

/ -----------------------------------------------------------------------------
/ Update Handler (called by TP via pub/sub)
/ -----------------------------------------------------------------------------

/ Receive trade update from Tickerplant
/ This is the main entry point for incoming data
/
/ Processing steps (tick-by-tick):
/   1. Extract relevant fields from incoming data
/   2. Initialize buffer if new symbol
/   3. Evict stale entries from buffer
/   4. Add new trade to buffer
/   5. Recompute analytics
/
/ @param tbl - Table name (always `trade_binance)
/ @param data - Row data as list (13 fields from TP)
.u.upd:{[tbl;data]
  / Extract fields from incoming trade
  / Schema positions (0-indexed):
  /   0: time, 1: sym, 2: tradeId, 3: price, 4: qty, 5: buyerIsMaker,
  /   6: exchEventTimeMs, 7: exchTradeTimeMs, 8: fhRecvTimeUtcNs,
  /   9: fhParseUs, 10: fhSendUs, 11: fhSeqNo, 12: tpRecvTimeUtcNs
  time:data 0;    / Trade timestamp (kdb format)
  s:data 1;       / Symbol (e.g., `BTCUSDT)
  price:data 3;   / Trade price
  
  / Current time for eviction calculation
  now:.z.p;
  
  / Initialize buffer for new symbol if first time seeing it
  if[not s in key .rte.buffer; .rte.initBuffer[s]];
  
  / Evict entries older than window
  .rte.evict[s;now];
  
  / Add new trade to buffer
  .rte.addTrade[s;time;price];
  
  / Recompute analytics for this symbol
  .rte.computeAnalytics[s;price;now];
  };

/ -----------------------------------------------------------------------------
/ Subscription to Tickerplant
/ -----------------------------------------------------------------------------

/ Connect to Tickerplant and subscribe to trade updates
.rte.connect:{[]
  / Build connection address (e.g., `:localhost:5010)
  addr:`$":",string[.rte.cfg.tpHost],":",string[.rte.cfg.tpPort];
  -1 "Connecting to tickerplant on port ",string[.rte.cfg.tpPort],"...";
  
  / Attempt connection with error handling
  h:@[hopen; addr; {-1 "Failed to connect to TP: ",x; 0N}];
  if[null h; '"Cannot connect to tickerplant"];
  
  / Subscribe to trade_binance table
  / Returns (table name; current schema)
  res:h (`.u.sub; `trade_binance; `);
  -1 "Subscribed to: ", string first res;
  
  / Store handle for potential later use
  .rte.tpHandle:h;
  };

/ -----------------------------------------------------------------------------
/ Startup
/ -----------------------------------------------------------------------------

/ Set listening port dynamically from config
system "p ",string .rte.cfg.port;

-1 "RTE starting on port ",string[.rte.cfg.port];
-1 "Window size: ",string[.rte.cfg.windowNs div 1000000000]," seconds";
-1 "Validity threshold: ",string[100 * .rte.cfg.validityThreshold],"%";

/ Connect and subscribe to TP
.rte.connect[];

-1 "RTE ready - tick-by-tick analytics enabled";

/ -----------------------------------------------------------------------------
/ End
/ -----------------------------------------------------------------------------
