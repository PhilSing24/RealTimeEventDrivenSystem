/ initialise table
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

/ canonical tickerplant update function
.u.upd:{[tbl; data]
  if[tbl=`trade_binance;
    trade_binance ,: enlist data
  ];
}
