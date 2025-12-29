#!/bin/bash
SESSION="market-data"

tmux kill-session -t $SESSION 2>/dev/null

tmux new-session -d -s $SESSION -n "pipeline"
tmux send-keys -t $SESSION "cd ~/binance_feed_handler && q kdb/tp.q" C-m

tmux split-window -h -t $SESSION
tmux send-keys -t $SESSION "sleep 2 && cd ~/binance_feed_handler && q kdb/rdb.q" C-m

tmux split-window -v -t $SESSION
tmux send-keys -t $SESSION "sleep 3 && cd ~/binance_feed_handler && q kdb/rte.q" C-m

tmux select-pane -t $SESSION:0.0
tmux split-window -v -t $SESSION
tmux send-keys -t $SESSION "sleep 4 && cd ~/binance_feed_handler && ./build/binance_feed_handler" C-m

tmux split-window -v -t $SESSION
tmux send-keys -t $SESSION "sleep 5 && cd ~/binance_feed_handler && ./build/binance_quote_handler" C-m

tmux select-layout -t $SESSION tiled
tmux attach -t $SESSION