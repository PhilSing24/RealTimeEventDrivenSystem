#!/bin/bash
# start.sh - Start all components in separate tmux windows
#
# Usage: ./start.sh
#
# Requires: tmux (install with: sudo apt install tmux)

SESSION="market-data"

# Kill existing session if it exists
tmux kill-session -t $SESSION 2>/dev/null

# Create new session with TP (window 0)
tmux new-session -d -s $SESSION -n "TP"
tmux send-keys -t $SESSION:TP "cd ~/binance_feed_handler && q kdb/tp.q" C-m

# Create RDB window
tmux new-window -t $SESSION -n "RDB"
tmux send-keys -t $SESSION:RDB "sleep 2 && cd ~/binance_feed_handler && q kdb/rdb.q" C-m

# Create RTE window
tmux new-window -t $SESSION -n "RTE"
tmux send-keys -t $SESSION:RTE "sleep 3 && cd ~/binance_feed_handler && q kdb/rte.q" C-m

# Create TEL window
tmux new-window -t $SESSION -n "TEL"
tmux send-keys -t $SESSION:TEL "sleep 4 && cd ~/binance_feed_handler && q kdb/tel.q" C-m

# Create FH window
tmux new-window -t $SESSION -n "FH"
tmux send-keys -t $SESSION:FH "sleep 5 && cd ~/binance_feed_handler && ./build/binance_feed_handler" C-m

# Select TP window
tmux select-window -t $SESSION:TP

# Attach to session
echo "Starting market data pipeline..."
echo "Windows: TP, RDB, RTE, TEL, FH"
echo ""
echo "Navigation:"
echo "  Ctrl+B n     - Next window"
echo "  Ctrl+B p     - Previous window"
echo "  Ctrl+B 0-4   - Jump to window by number"
echo "  Ctrl+B d     - Detach (keeps running)"
echo ""
echo "Run 'tmux attach -t market-data' to reattach"
tmux attach-session -t $SESSION
