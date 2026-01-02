/**
 * @file quote_feed_handler.hpp
 * @brief WebSocket depth stream handler with snapshot reconciliation
 * 
 * Implements the full L1 book lifecycle:
 *   1. Connect to @depth WebSocket stream
 *   2. Buffer incoming deltas
 *   3. Fetch REST snapshot
 *   4. Apply snapshot + buffered deltas
 *   5. Continue applying live deltas
 *   6. Publish L1 on change/timeout
 * 
 * State machine:
 *   INIT → (start buffering) → SYNCING → (snapshot + deltas) → VALID
 *   VALID → (sequence gap) → INVALID → INIT (rebuild)
 * 
 * @see docs/decisions/adr-002-Feed-handler-to-kdb-ingestion-path.md
 * @see docs/decisions/adr-008-Error-Handling-Strategy.md
 * @see docs/decisions/adr-009-L1-Order-Book-Architecture.md
 */

#ifndef QUOTE_FEED_HANDLER_HPP
#define QUOTE_FEED_HANDLER_HPP

#include <boost/beast/core.hpp>
#include <boost/beast/websocket.hpp>
#include <boost/beast/ssl.hpp>
#include <boost/asio/connect.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/ssl/context.hpp>

#include <string>
#include <vector>
#include <unordered_map>
#include <deque>
#include <atomic>

#include "order_book.hpp"
#include "rest_client.hpp"

extern "C" {
#include "k.h"
}

namespace beast = boost::beast;
namespace websocket = beast::websocket;
namespace net = boost::asio;
namespace ssl = net::ssl;
using tcp = net::ip::tcp;

/**
 * @brief Buffered delta for replay after snapshot
 */
struct BufferedDelta {
    long long firstUpdateId;
    long long finalUpdateId;
    long long eventTimeMs;
    std::vector<PriceLevel> bids;
    std::vector<PriceLevel> asks;
};

/**
 * @brief Per-symbol state for quote handling
 */
struct SymbolState {
    OrderBook book;
    L1Publisher publisher;
    std::deque<BufferedDelta> deltaBuffer;
    bool snapshotRequested = false;
    
    explicit SymbolState(const std::string& sym) 
        : book(sym), publisher(sym) {}
};

/**
 * @class QuoteFeedHandler
 * @brief Handles real-time L1 quote data from Binance depth streams
 * 
 * Key responsibilities:
 *   - WebSocket connection management (TLS) with auto-reconnect
 *   - Order book state management (INIT → SYNCING → VALID)
 *   - REST snapshot fetching for initial sync
 *   - Delta buffering and replay
 *   - L1 quote extraction and publication
 *   - Graceful shutdown on signal
 */
class QuoteFeedHandler {
public:
    // ========================================================================
    // CONFIGURATION CONSTANTS
    // ========================================================================
    
    /// Binance WebSocket host
    static constexpr const char* BINANCE_HOST = "stream.binance.com";
    
    /// Binance WebSocket port (TLS)
    static constexpr const char* BINANCE_PORT = "9443";
    
    /// Nanoseconds between Unix epoch (1970) and kdb+ epoch (2000)
    static constexpr long long KDB_EPOCH_OFFSET_NS = 946684800000000000LL;
    
    /// Initial reconnection backoff (milliseconds)
    static constexpr int INITIAL_BACKOFF_MS = 1000;
    
    /// Maximum reconnection backoff (milliseconds)
    static constexpr int MAX_BACKOFF_MS = 8000;
    
    /// Backoff multiplier
    static constexpr int BACKOFF_MULTIPLIER = 2;

    // ========================================================================
    // CONSTRUCTION
    // ========================================================================
    
    /**
     * @brief Construct a quote feed handler
     * @param symbols List of symbols to subscribe to (lowercase, e.g., "btcusdt")
     * @param tpHost Tickerplant hostname
     * @param tpPort Tickerplant port
     */
    QuoteFeedHandler(const std::vector<std::string>& symbols,
                     const std::string& tpHost = "localhost",
                     int tpPort = 5010);
    
    /// Destructor - ensures cleanup
    ~QuoteFeedHandler();
    
    // Non-copyable
    QuoteFeedHandler(const QuoteFeedHandler&) = delete;
    QuoteFeedHandler& operator=(const QuoteFeedHandler&) = delete;

    // ========================================================================
    // PUBLIC INTERFACE
    // ========================================================================
    
    /**
     * @brief Run the feed handler (blocking)
     * 
     * Connects to Binance and TP, then processes messages until stop() is called.
     * Automatically reconnects on disconnection.
     */
    void run();
    
    /**
     * @brief Request graceful shutdown
     * 
     * Thread-safe. Can be called from signal handler.
     */
    void stop();
    
    /**
     * @brief Check if handler is running
     */
    bool isRunning() const { return running_.load(); }
    
    /**
     * @brief Get count of messages processed
     */
    long long messageCount() const { return fhSeqNo_; }

private:
    // ========================================================================
    // CONFIGURATION
    // ========================================================================
    
    std::vector<std::string> symbols_;
    std::string tpHost_;
    int tpPort_;
    
    // ========================================================================
    // STATE
    // ========================================================================
    
    /// Shutdown flag
    std::atomic<bool> running_{true};
    
    /// Per-symbol state (order books, publishers, buffers)
    std::unordered_map<std::string, SymbolState> states_;
    
    /// Tickerplant connection handle
    int tpHandle_{-1};
    
    /// FH sequence number
    long long fhSeqNo_{0};
    
    /// Binance reconnection attempt counter
    int binanceReconnectAttempt_{0};
    
    /// REST client for snapshots
    RestClient restClient_;
    
    // ========================================================================
    // HEALTH TRACKING
    // ========================================================================
    
    /// Handler start time (for uptime calculation)
    std::chrono::system_clock::time_point startTime_;
    
    /// Total messages received from Binance
    long long msgsReceived_{0};
    
    /// Total messages published to TP
    long long msgsPublished_{0};
    
    /// Time of last message received
    std::chrono::system_clock::time_point lastMsgTime_;
    
    /// Time of last publish to TP
    std::chrono::system_clock::time_point lastPubTime_;
    
    /// Current connection state
    std::string connState_{"disconnected"};
    
    /// Health publish interval in seconds
    static constexpr int HEALTH_INTERVAL_SEC = 5;

    // ========================================================================
    // PRIVATE METHODS
    // ========================================================================
    
    /// Build WebSocket path for depth streams
    std::string buildDepthStreamPath() const;
    
    /// Connect to tickerplant with retry
    bool connectToTP();
    
    /// Sleep with exponential backoff
    bool sleepWithBackoff(int attempt);
    
    /// Reset all order books (on reconnect)
    void resetAllBooks();
    
    /// Process incoming WebSocket message
    void processMessage(const std::string& msg, long long fhRecvTimeUtcNs);
    
    /// Handle delta based on current book state
    void handleDelta(SymbolState& state, const BufferedDelta& delta, long long fhRecvTimeUtcNs);
    
    /// Request and apply snapshot
    void requestSnapshot(SymbolState& state);
    
    /// Check if should publish and do it
    void maybePublish(SymbolState& state, long long fhRecvTimeUtcNs);
    
    /// Publish invalid state
    void publishInvalid(SymbolState& state, long long fhRecvTimeUtcNs);
    
    /// Publish L1 quote to kdb+
    void publishL1(const L1Quote& quote);
    
    /// Check publish timeouts for all symbols
    void checkPublishTimeouts(long long fhRecvTimeUtcNs);
    
    /// Run the WebSocket connection loop
    void runWebSocketLoop();
    
    /// Publish health metrics to TP
    void publishHealth();
};

#endif // QUOTE_FEED_HANDLER_HPP
