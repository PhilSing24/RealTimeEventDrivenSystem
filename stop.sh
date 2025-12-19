#!/bin/bash
tmux kill-session -t market-data 2>/dev/null
pkill -f "binance_feed_handler" 2>/dev/null
pkill -f "q kdb/" 2>/dev/null
echo "Done."
