/ -------------------------------------------------------
/ rdb.q
/ Minimal Real-Time Database (RDB)
/ -------------------------------------------------------

/ Load common definitions if needed (optional)
/ (Do NOT load tp.q logic here)

/ -------------------------------------------------------
/ Tables (query-consistent state)
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
  fhRecvTimeUtcNs:`long$()
  );

/ -------------------------------------------------------
/ Subscription to Tickerplant
/ -------------------------------------------------------

/ Connect to TP on localhost port 5010
.u.sub[`::5010; `trade_binance; ``];

/ -------------------------------------------------------
/ End
/ -------------------------------------------------------
