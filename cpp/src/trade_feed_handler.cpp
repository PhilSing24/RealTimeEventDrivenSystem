/**
 * @file trade_feed_handler.cpp
 * @brief Implementation of TradeFeedHandler class
 */

#include "trade_feed_handler.hpp"

#include <rapidjson/document.h>

#include <iostream>
#include <chrono>
#include <thread>
#include <csignal>

// ============================================================================
// CONSTRUCTION / DESTRUCTION
// ============================================================================

TradeFeedHandler::TradeFeedHandler(const std::vector<std::string>& symbols,
                                   const std::string& tpHost,
                                   int tpPort)
    : symbols_(symbols)
    , tpHost_(tpHost)
    , tpPort_(tpPort)
{
}

TradeFeedHandler::~TradeFeedHandler() {
    if (tpHandle_ > 0) {
        kclose(tpHandle_);
        std::cout << "[Trade FH] TP connection closed in destructor\n";
    }
}

// ============================================================================
// PUBLIC INTERFACE
// ============================================================================

void TradeFeedHandler::run() {
    std::cout << "[Trade FH] Starting...\n";
    std::cout << "[Trade FH] Symbols: ";
    for (const auto& s : symbols_) std::cout << s << " ";
    std::cout << "\n";
    
    // Connect to tickerplant (retries until success or shutdown)
    if (!connectToTP()) {
        std::cout << "[Trade FH] Shutdown before TP connection established\n";
        return;
    }
    
    // Main loop with reconnection
    while (running_) {
        try {
            runWebSocketLoop();
        } catch (const std::exception& e) {
            if (!running_) {
                std::cout << "[Trade FH] Connection closed during shutdown\n";
            } else {
                std::cerr << "[Trade FH] Binance error: " << e.what() << "\n";
                std::cerr << "[Trade FH] Will reconnect...\n";
                if (!sleepWithBackoff(binanceReconnectAttempt_++)) {
                    break;  // Shutdown requested during backoff
                }
            }
        }
    }
    
    // Cleanup
    std::cout << "[Trade FH] Cleaning up...\n";
    if (tpHandle_ > 0) {
        kclose(tpHandle_);
        tpHandle_ = -1;
        std::cout << "[Trade FH] TP connection closed\n";
    }
    
    std::cout << "[Trade FH] Shutdown complete (processed " << fhSeqNo_ << " messages)\n";
}

void TradeFeedHandler::stop() {
    std::cout << "[Trade FH] Stop requested\n";
    running_ = false;
}

// ============================================================================
// PRIVATE METHODS
// ============================================================================

std::string TradeFeedHandler::buildStreamPath() const {
    std::string path = "/stream?streams=";
    for (size_t i = 0; i < symbols_.size(); ++i) {
        if (i > 0) path += "/";
        path += symbols_[i] + "@trade";
    }
    return path;
}

bool TradeFeedHandler::connectToTP() {
    int attempt = 0;
    while (running_) {
        std::cout << "[Trade FH] Connecting to TP on " << tpHost_ << ":" << tpPort_ << "...\n";
        
        int h = khpu((S)tpHost_.c_str(), tpPort_, (S)"");
        
        if (h > 0) {
            tpHandle_ = h;
            std::cout << "[Trade FH] Connected to TP (handle " << h << ")\n";
            return true;
        }
        
        std::cerr << "[Trade FH] Failed to connect to TP\n";
        if (!sleepWithBackoff(attempt++)) {
            return false;  // Shutdown requested
        }
    }
    return false;  // Shutdown requested
}

bool TradeFeedHandler::sleepWithBackoff(int attempt) {
    int delay = INITIAL_BACKOFF_MS;
    for (int i = 0; i < attempt && delay < MAX_BACKOFF_MS; ++i) {
        delay *= BACKOFF_MULTIPLIER;
    }
    delay = std::min(delay, MAX_BACKOFF_MS);
    
    std::cout << "[Trade FH] Waiting " << delay << "ms before reconnect...\n";
    
    // Sleep in small increments to allow quick shutdown response
    const int checkIntervalMs = 100;
    int slept = 0;
    while (slept < delay && running_) {
        std::this_thread::sleep_for(std::chrono::milliseconds(checkIntervalMs));
        slept += checkIntervalMs;
    }
    
    return running_;
}

void TradeFeedHandler::validateTradeId(const std::string& sym, long long tradeId) {
    auto it = lastTradeId_.find(sym);
    
    if (it != lastTradeId_.end()) {
        long long last = it->second;
        
        if (tradeId < last) {
            std::cerr << "[Trade FH] OUT OF ORDER: " << sym 
                      << " last=" << last 
                      << " got=" << tradeId << std::endl;
        } else if (tradeId == last) {
            std::cerr << "[Trade FH] DUPLICATE: " << sym 
                      << " tradeId=" << tradeId << std::endl;
        } else if (tradeId > last + 1) {
            long long missed = tradeId - last - 1;
            std::cout << "[Trade FH] Gap: " << sym 
                      << " missed=" << missed 
                      << " (last=" << last << " got=" << tradeId << ")" << std::endl;
        }
    }
    
    lastTradeId_[sym] = tradeId;
}

void TradeFeedHandler::processMessage(const std::string& msg) {
    // Capture wall-clock receive time (for cross-process correlation)
    auto recvWall = std::chrono::system_clock::now();
    long long fhRecvTimeUtcNs =
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            recvWall.time_since_epoch()).count();
    
    // Start monotonic timer for parse latency
    auto parseStart = std::chrono::steady_clock::now();
    
    // Parse JSON
    rapidjson::Document doc;
    doc.Parse(msg.c_str());
    if (!doc.IsObject()) return;
    
    // Combined stream format: {"stream":"btcusdt@trade","data":{...}}
    if (!doc.HasMember("data")) return;
    const rapidjson::Value& d = doc["data"];
    
    if (!d.IsObject()) return;
    if (!d.HasMember("s")) return;
    
    // Extract trade fields
    const char* sym = d["s"].GetString();
    long long tradeId = d["t"].GetInt64();
    double price = std::stod(d["p"].GetString());
    double qty = std::stod(d["q"].GetString());
    bool buyerIsMaker = d["m"].GetBool();
    long long exchEventTimeMs = d["E"].GetInt64();
    long long exchTradeTimeMs = d["T"].GetInt64();
    
    // Validate sequence
    validateTradeId(sym, tradeId);
    
    // End parse timer
    auto parseEnd = std::chrono::steady_clock::now();
    long long fhParseUs = std::chrono::duration_cast<std::chrono::microseconds>(
        parseEnd - parseStart).count();
    
    // Increment sequence number
    ++fhSeqNo_;
    
    // Build kdb+ row
    K row = knk(12,
        ktj(-KP, fhRecvTimeUtcNs - KDB_EPOCH_OFFSET_NS),
        ks((S)sym),
        kj(tradeId),
        kf(price),
        kf(qty),
        kb(buyerIsMaker),
        kj(exchEventTimeMs),
        kj(exchTradeTimeMs),
        kj(fhRecvTimeUtcNs),
        kj(fhParseUs),
        kj(0LL),  // fhSendUs placeholder
        kj(fhSeqNo_)
    );
    
    // Capture send time
    auto sendEnd = std::chrono::steady_clock::now();
    long long fhSendUs = std::chrono::duration_cast<std::chrono::microseconds>(
        sendEnd - parseEnd).count();
    kK(row)[10]->j = fhSendUs;
    
    // Console output
    std::cout
        << "sym=" << sym
        << " tradeId=" << tradeId
        << " price=" << price
        << " qty=" << qty
        << " fhParseUs=" << fhParseUs
        << " fhSendUs=" << fhSendUs
        << " fhSeqNo=" << fhSeqNo_
        << std::endl;
    
    // Publish to TP
    K result = k(-tpHandle_, (S)".u.upd", ks((S)"trade_binance"), row, (K)0);
    
    // Check if TP connection died
    if (result == nullptr) {
        std::cerr << "[Trade FH] TP connection lost, reconnecting...\n";
        kclose(tpHandle_);
        tpHandle_ = -1;
        if (connectToTP()) {
            // Resend to new connection
            k(-tpHandle_, (S)".u.upd", ks((S)"trade_binance"), row, (K)0);
        }
    }
}

void TradeFeedHandler::runWebSocketLoop() {
    std::string target = buildStreamPath();
    std::cout << "[Trade FH] Connecting to Binance: " << BINANCE_HOST << target << "\n";
    
    // Initialize ASIO and SSL
    net::io_context ioc;
    ssl::context ctx{ssl::context::tlsv12_client};
    ctx.set_default_verify_paths();
    
    // Resolve and connect
    tcp::resolver resolver{ioc};
    websocket::stream<beast::ssl_stream<tcp::socket>> ws{ioc, ctx};
    
    auto const results = resolver.resolve(BINANCE_HOST, BINANCE_PORT);
    net::connect(ws.next_layer().next_layer(), results.begin(), results.end());
    
    // TLS handshake
    ws.next_layer().handshake(ssl::stream_base::client);
    
    // WebSocket handshake
    ws.handshake(BINANCE_HOST, target);
    
    std::cout << "[Trade FH] Connected to Binance (" << symbols_.size() << " symbols)\n";
    
    // Reset backoff on successful connection
    binanceReconnectAttempt_ = 0;
    
    // Message loop
    while (running_) {
        beast::flat_buffer buffer;
        ws.read(buffer);
        
        if (!running_) break;
        
        std::string msg = beast::buffers_to_string(buffer.data());
        processMessage(msg);
    }
    
    // Graceful close
    if (!running_) {
        try {
            ws.close(websocket::close_code::normal);
            std::cout << "[Trade FH] WebSocket closed gracefully\n";
        } catch (...) {
            // Ignore errors during shutdown
        }
    }
}

// ============================================================================
// CONFIGURATION
// ============================================================================

// Symbols to subscribe to (lowercase for Binance stream names)
static const std::vector<std::string> SYMBOLS = {
    "btcusdt",
    "ethusdt"
};

// Tickerplant connection
static const std::string TP_HOST = "localhost";
static const int TP_PORT = 5010;

// ============================================================================
// SIGNAL HANDLING
// ============================================================================

// Global pointer for signal handler access
static TradeFeedHandler* g_handler = nullptr;

static void signalHandler(int signum) {
    const char* sigName = (signum == SIGINT) ? "SIGINT" : 
                          (signum == SIGTERM) ? "SIGTERM" : "UNKNOWN";
    std::cout << "\n[Trade FH] Received " << sigName << " (" << signum << ")\n";
    
    if (g_handler) {
        g_handler->stop();
    }
}

// ============================================================================
// MAIN
// ============================================================================

int main() {
    std::cout << "=== Binance Trade Feed Handler ===\n";
    
    // Install signal handlers
    std::signal(SIGINT, signalHandler);
    std::signal(SIGTERM, signalHandler);
    std::cout << "[Trade FH] Signal handlers installed (Ctrl+C to shutdown)\n";
    
    // Create and run handler
    TradeFeedHandler handler(SYMBOLS, TP_HOST, TP_PORT);
    g_handler = &handler;
    
    handler.run();
    
    g_handler = nullptr;
    std::cout << "[Trade FH] Exiting\n";
    return 0;
}
