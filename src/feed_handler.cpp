/**
 * @file feed_handler.cpp
 * @brief Real-time Binance trade feed handler with kdb+ IPC publishing
 * 
 * This feed handler connects to Binance WebSocket streams, receives real-time
 * trade events, normalizes them, and publishes to a kdb+ tickerplant via IPC.
 * 
 * Architecture role:
 *   Binance WebSocket -> [Feed Handler] -> Tickerplant -> RDB/RTE
 * 
 * Key responsibilities:
 *   - WebSocket connection management (TLS) with auto-reconnect
 *   - JSON parsing and normalization
 *   - Timestamp capture (wall-clock and monotonic)
 *   - Latency instrumentation (parse time, send time)
 *   - Sequence numbering for gap detection
 *   - IPC publication to tickerplant with reconnect
 * 
 * Design decisions:
 *   - Tick-by-tick publishing (no batching) for latency measurement clarity
 *   - Async IPC (neg handle) to minimize blocking
 *   - Combined stream subscription for multi-symbol support
 *   - Reconnect with exponential backoff on disconnect
 * 
 * @see docs/decisions/adr-001-Timestamps-and-latency-measurement.md
 * @see docs/decisions/adr-002-Feed-handler-to-kdb-ingestion-path.md
 * @see docs/decisions/adr-008-Error-Handling-Strategy.md
 * @see docs/specs/trades-schema.md
 * @see https://code.kx.com/q/wp/capi/ (kdb+ C API reference)
 */

#include <boost/beast/core.hpp>        // Buffer handling
#include <boost/beast/websocket.hpp>   // WebSocket protocol
#include <boost/beast/ssl.hpp>         // TLS/SSL encryption
#include <boost/asio/connect.hpp>      // TCP connection
#include <boost/asio/ip/tcp.hpp>       // TCP sockets
#include <boost/asio/ssl/context.hpp>  // SSL context

#include <rapidjson/document.h>

#include <iostream>
#include <string>
#include <chrono>
#include <vector>
#include <thread>

// kdb+ C API header (extern "C" required for C++ linkage)
extern "C" {
#include "k.h"
}

// Namespace aliases for cleaner code
namespace beast = boost::beast;
namespace websocket = beast::websocket;
namespace net = boost::asio;
namespace ssl = net::ssl;
using tcp = net::ip::tcp;

// ============================================================================
// CONFIGURATION
// ============================================================================
// Symbols to subscribe to. Lowercase required for Binance stream names.
// Add or remove symbols here to change subscription scope.
const std::vector<std::string> SYMBOLS = {
    "btcusdt",
    "ethusdt"
};

/**
 * Epoch offset: nanoseconds between Unix epoch (1970.01.01) and kdb+ epoch (2000.01.01)
 * 
 * kdb+ timestamps use 2000.01.01 as epoch zero.
 * Unix/C++ timestamps use 1970.01.01 as epoch zero.
 * This constant converts between the two: kdb_ns = unix_ns - KDB_EPOCH_OFFSET_NS
 */
const long long KDB_EPOCH_OFFSET_NS = 946684800000000000LL;

// Reconnection settings
const int INITIAL_BACKOFF_MS = 1000;    // Start with 1 second
const int MAX_BACKOFF_MS = 8000;        // Max 8 seconds
const int BACKOFF_MULTIPLIER = 2;

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

/**
 * @brief Build Binance combined stream path for multiple symbols
 * 
 * Binance combined streams use format: /stream?streams=sym1@trade/sym2@trade
 * This allows subscribing to multiple trade streams on a single WebSocket.
 * 
 * @param symbols Vector of lowercase symbol names (e.g., "btcusdt")
 * @return Stream path string for WebSocket handshake
 * 
 * Example: {"btcusdt", "ethusdt"} -> "/stream?streams=btcusdt@trade/ethusdt@trade"
 */
std::string buildStreamPath(const std::vector<std::string>& symbols) {
    std::string path = "/stream?streams=";
    for (size_t i = 0; i < symbols.size(); ++i) {
        if (i > 0) path += "/";
        path += symbols[i] + "@trade";
    }
    return path;
}

/**
 * @brief Sleep with exponential backoff
 * @param attempt Current attempt number (0-based)
 * @return Actual sleep duration in milliseconds
 */
int sleepWithBackoff(int attempt) {
    int delay = INITIAL_BACKOFF_MS;
    for (int i = 0; i < attempt && delay < MAX_BACKOFF_MS; ++i) {
        delay *= BACKOFF_MULTIPLIER;
    }
    delay = std::min(delay, MAX_BACKOFF_MS);
    
    std::cout << "[FH] Waiting " << delay << "ms before reconnect...\n";
    std::this_thread::sleep_for(std::chrono::milliseconds(delay));
    return delay;
}

// ============================================================================
// TICKERPLANT CONNECTION
// ============================================================================

/**
 * @brief Connect to tickerplant with retry logic
 * @return Handle (>0) on success, keeps retrying until success
 */
int connectToTP() {
    int attempt = 0;
    while (true) {
        std::cout << "[FH] Connecting to TP on port 5010...\n";
        // khpu: connect with host, port, credentials (empty = no auth)
        // Returns handle > 0 on success, <= 0 on failure
        int h = khpu((S)"localhost", 5010, (S)"");
        
        if (h > 0) {
            std::cout << "[FH] Connected to TP (handle " << h << ")\n";
            return h;
        }
        
        std::cerr << "[FH] Failed to connect to TP\n";
        sleepWithBackoff(attempt++);
    }
}

// ============================================================================
// MAIN FEED HANDLER
// ============================================================================

/**
 * @brief Main feed handler loop
 * 
 * Establishes WebSocket connection to Binance, receives trade events,
 * and publishes them to the tickerplant. Runs indefinitely with auto-reconnect.
 * 
 * @return 0 on clean exit (never returns under normal operation)
 */
int run_feed_handler() {
    std::cout << "[FH] Feed handler starting...\n";
    std::cout << "[FH] Symbols: ";
    for (const auto& s : SYMBOLS) std::cout << s << " ";
    std::cout << "\n";

    // ---- Binance connection parameters ----
    const std::string host = "stream.binance.com";
    const std::string port = "9443";  // TLS port
    const std::string target = buildStreamPath(SYMBOLS);

    // ---- Connect to kdb+ tickerplant (retries until success) ----
    int tp = connectToTP();

    // ---- Sequence number for gap detection ----
    // Monotonically increasing per FH instance
    // Persists across Binance reconnects (but resets on FH restart)
    // Downstream can detect gaps by checking for non-contiguous values
    long long fhSeqNo = 0;

    // Binance reconnect attempt counter
    int binanceReconnectAttempt = 0;

    // ========================================================================
    // OUTER LOOP - Handles Binance reconnection
    // ========================================================================
    while (true) {
        try {
            std::cout << "[FH] Connecting to Binance: " << host << target << "\n";

            // ---- Initialize ASIO and SSL context ----
            net::io_context ioc;
            ssl::context ctx{ssl::context::tlsv12_client};
            ctx.set_default_verify_paths();  // Use system CA certificates

            // ---- Resolve hostname and connect ----
            tcp::resolver resolver{ioc};
            websocket::stream<beast::ssl_stream<tcp::socket>> ws{ioc, ctx};

            auto const results = resolver.resolve(host, port);
            net::connect(ws.next_layer().next_layer(), results.begin(), results.end());
            
            // ---- TLS handshake ----
            ws.next_layer().handshake(ssl::stream_base::client);
            
            // ---- WebSocket handshake ----
            ws.handshake(host, target);

            std::cout << "[FH] Connected to Binance (" << SYMBOLS.size() << " symbols)\n";
            
            // Reset backoff on successful connection
            binanceReconnectAttempt = 0;

            // ================================================================
            // INNER LOOP - Message processing
            // ================================================================
            for (;;) {
                // ---- Read WebSocket message ----
                beast::flat_buffer buffer;
                ws.read(buffer);

                // ---- Capture wall-clock receive time (UTC) ----
                // Used for cross-process latency correlation
                // system_clock provides wall-clock time (subject to NTP adjustments)
                auto recvWall = std::chrono::system_clock::now();
                long long fhRecvTimeUtcNs =
                    std::chrono::duration_cast<std::chrono::nanoseconds>(
                        recvWall.time_since_epoch()).count();

                // ---- Start monotonic timer for parse latency ----
                // steady_clock is monotonic (never goes backwards)
                // Used for reliable duration measurement within this process
                auto parseStart = std::chrono::steady_clock::now();

                // ---- Parse JSON message ----
                std::string msg = beast::buffers_to_string(buffer.data());

                rapidjson::Document doc;
                doc.Parse(msg.c_str());
                if (!doc.IsObject()) continue;  // Skip malformed messages

                // ---- Extract trade data from combined stream format ----
                // Combined stream wraps payload: {"stream":"btcusdt@trade","data":{...}}
                if (!doc.HasMember("data")) continue;
                const rapidjson::Value& d = doc["data"];

                if (!d.IsObject()) continue;
                if (!d.HasMember("s")) continue;  // "s" = symbol

                // ---- Extract and normalize trade fields ----
                // See: https://binance-docs.github.io/apidocs/spot/en/#trade-streams
                const char* sym = d["s"].GetString();        // Symbol (uppercase from Binance)
                long long tradeId = d["t"].GetInt64();       // Trade ID (unique per symbol)
                double price = std::stod(d["p"].GetString());// Price (string -> double)
                double qty = std::stod(d["q"].GetString());  // Quantity (string -> double)
                bool buyerIsMaker = d["m"].GetBool();        // True if buyer is market maker
                long long exchEventTimeMs = d["E"].GetInt64(); // Exchange event time (ms)
                long long exchTradeTimeMs = d["T"].GetInt64(); // Exchange trade time (ms)

                // ---- End monotonic timer for parse latency ----
                auto parseEnd = std::chrono::steady_clock::now();
                long long fhParseUs = std::chrono::duration_cast<std::chrono::microseconds>(
                    parseEnd - parseStart).count();

                // ---- Increment sequence number ----
                ++fhSeqNo;

                // ---- Build kdb+ row ----
                // Column order must match table schema in tp.q
                // knk: create mixed list (K object with n elements)
                // ktj(-KP, ns): create timestamp from nanoseconds (negative type = atom)
                // ks: create symbol
                // kj: create long
                // kf: create float
                // kb: create boolean
                K row = knk(12,
                    ktj(-KP, fhRecvTimeUtcNs - KDB_EPOCH_OFFSET_NS),  // ns since 01.01.2000 (kdb epoch). -KP cause it's an atom
                    ks((S)sym),                       // sym
                    kj(tradeId),                      // tradeId
                    kf(price),                        // price
                    kf(qty),                          // qty
                    kb(buyerIsMaker),                 // buyerIsMaker
                    kj(exchEventTimeMs),              // exchEventTimeMs
                    kj(exchTradeTimeMs),              // exchTradeTimeMs
                    kj(fhRecvTimeUtcNs),              // fhRecvTimeUtcNs (raw Unix epoch)
                    kj(fhParseUs),                    // fhParseUs
                    kj(0LL),                          // fhSendUs (placeholder, updated below)
                    kj(fhSeqNo)                       // fhSeqNo
                );

                // ---- Capture send preparation time ----
                auto sendEnd = std::chrono::steady_clock::now();
                long long fhSendUs = std::chrono::duration_cast<std::chrono::microseconds>(
                    sendEnd - parseEnd).count();

                // Update fhSendUs in row (index 10 in the knk list)
                // kK(row) returns the K* array, [10]->j accesses the long value
                kK(row)[10]->j = fhSendUs;

                // ---- Console output for debugging ----
                std::cout
                    << "sym=" << sym
                    << " tradeId=" << tradeId
                    << " price=" << price
                    << " qty=" << qty
                    << " fhParseUs=" << fhParseUs
                    << " fhSendUs=" << fhSendUs
                    << " fhSeqNo=" << fhSeqNo
                    << std::endl;

                // ---- Publish to tickerplant via async IPC ----
                // k(-tp, ...): negative handle = async (non-blocking)
                // .u.upd: standard tickerplant update function
                // "trade_binance": target table name
                // row: the data row
                // (K)0: null terminator for variadic k() function
                K result = k(-tp, (S)".u.upd", ks((S)"trade_binance"), row, (K)0);
                
                // Check if TP connection died
                if (result == nullptr) {
                    std::cerr << "[FH] TP connection lost, reconnecting...\n";
                    kclose(tp);
                    tp = connectToTP();
                    // Resend this message to new connection
                    k(-tp, (S)".u.upd", ks((S)"trade_binance"), row, (K)0);
                }
            }

        } catch (const std::exception& e) {
            std::cerr << "[FH] Binance error: " << e.what() << "\n";
            std::cerr << "[FH] Will reconnect...\n";
            sleepWithBackoff(binanceReconnectAttempt++);
            // Loop continues, will reconnect to Binance
        }
    }

    return 0;
}
