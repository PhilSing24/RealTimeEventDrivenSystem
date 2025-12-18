#!/bin/bash
# stop.sh - Stop all components
#
# Usage: ./stop.sh

SESSION="market-data"

echo "Stopping market data pipeline..."

# Kill tmux session (stops all processes)
tmux kill-session -t $SESSION 2>/dev/null

# Also kill any stray processes
pkill -f "binance_feed_handler" 2>/dev/null
pkill -f "q kdb/tp.q" 2>/dev/null
pkill -f "q kdb/rdb.q" 2>/dev/null
pkill -f "q kdb/rte.q" 2>/dev/null

echo "Done."
