#!/bin/bash
# start.sh - Start all components in tmux panes
#
# Usage: ./start.sh
#
# Requires: tmux (install with: sudo apt install tmux)

SESSION="market-data"

# Kill existing session if it exists
tmux kill-session -t $SESSION 2>/dev/null

# Create new session with TP
tmux new-session -d -s $SESSION -n "pipeline"
tmux send-keys -t $SESSION "cd ~/binance_feed_handler && q kdb/tp.q" C-m

# Split and start RDB
tmux split-window -h -t $SESSION
tmux send-keys -t $SESSION "sleep 2 && cd ~/binance_feed_handler && q kdb/rdb.q" C-m

# Split and start RTE
tmux split-window -v -t $SESSION
tmux send-keys -t $SESSION "sleep 3 && cd ~/binance_feed_handler && q kdb/rte.q" C-m

# Select first pane and split for FH
tmux select-pane -t $SESSION:0.0
tmux split-window -v -t $SESSION
tmux send-keys -t $SESSION "sleep 4 && cd ~/binance_feed_handler && ./build/binance_feed_handler" C-m

# Arrange panes evenly
tmux select-layout -t $SESSION tiled

# Attach to session
echo "Starting market data pipeline..."
echo "Press Ctrl+B then D to detach (keeps running)"
echo "Run 'tmux attach -t $SESSION' to reattach"
tmux attach -t $SESSION
