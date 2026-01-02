#!/bin/bash
# stop.sh - Stop all market data pipeline components
#
# Usage: ./stop.sh

echo "Stopping market data pipeline..."

# Kill tmux session (stops all processes in panes)
tmux kill-session -t market-data 2>/dev/null

# Kill any stray processes
pkill -f "trade_feed_handler" 2>/dev/null
pkill -f "quote_feed_handler" 2>/dev/null
pkill -f "q kdb/" 2>/dev/null

echo "Done."
