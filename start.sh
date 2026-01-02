#!/bin/bash
# start.sh - Start all components in separate tmux windows
#
# Usage: ./start.sh
#
# Components started:
#   - Tickerplant (port 5010)
#   - RDB (port 5011)
#   - RTE (port 5012)
#   - Trade Feed Handler (connects to TP)
#   - Quote Feed Handler (connects to TP)
#
# Requires: tmux (install with: sudo apt install tmux)
#
# Navigation:
#   Ctrl+B then N = next window
#   Ctrl+B then P = previous window
#   Ctrl+B then 0-4 = jump to window number
#   Ctrl+B then D = detach (keeps running)

SESSION="market-data"

tmux kill-session -t $SESSION 2>/dev/null

# Window 0: Tickerplant
tmux new-session -d -s $SESSION -n "tp"
tmux send-keys -t $SESSION:tp "cd ~/binance_feed_handler && q kdb/tp.q" C-m

# Window 1: RDB
tmux new-window -t $SESSION -n "rdb"
tmux send-keys -t $SESSION:rdb "sleep 2 && cd ~/binance_feed_handler && q kdb/rdb.q" C-m

# Window 2: RTE
tmux new-window -t $SESSION -n "rte"
tmux send-keys -t $SESSION:rte "sleep 3 && cd ~/binance_feed_handler && q kdb/rte.q" C-m

# Window 3: Trade Feed Handler
tmux new-window -t $SESSION -n "trade-fh"
tmux send-keys -t $SESSION:trade-fh "sleep 4 && cd ~/binance_feed_handler && ./build/trade_feed_handler" C-m

# Window 4: Quote Feed Handler
tmux new-window -t $SESSION -n "quote-fh"
tmux send-keys -t $SESSION:quote-fh "sleep 5 && cd ~/binance_feed_handler && ./build/quote_feed_handler" C-m

# Select first window
tmux select-window -t $SESSION:tp

echo "Starting market data pipeline..."
echo ""
echo "Navigation:"
echo "  Ctrl+B then N     = next window"
echo "  Ctrl+B then P     = previous window"
echo "  Ctrl+B then 0-4   = jump to window"
echo "  Ctrl+B then D     = detach (keeps running)"
echo ""
echo "Run 'tmux attach -t $SESSION' to reattach"
echo ""

tmux attach -t $SESSION
