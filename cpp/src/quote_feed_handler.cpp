/**
 * @file quote_feed_handler.cpp
 * @brief Implementation of QuoteFeedHandler class
 */

#include "quote_feed_handler.hpp"

#include <rapidjson/document.h>
#include <spdlog/spdlog.h>

#include <iostream>
#include <chrono>
#include <thread>
#include <csignal>

// ============================================================================
// CONSTRUCTION / DESTRUCTION
// ============================================================================

QuoteFeedHandler::QuoteFeedHandler(const std::vector<std::string>& symbols,
                                   const std::string& tpHost,
                                   int tpPort)
    : symbols_(symbols)
    , tpHost_(tpHost)
    , tpPort_(tpPort)
    , startTime_(std::chrono::system_clock::now())
{
    // Initialize per-symbol state
    for (const auto& sym : symbols) {
        // Convert to uppercase for internal use
        std::string upper = sym;
        for (auto& c : upper) c = std::toupper(c);
        states_.emplace(upper, SymbolState(upper));
    }
}

QuoteFeedHandler::~QuoteFeedHandler() {
    if (tpHandle_ > 0) {
        kclose(tpHandle_);
        spdlog::debug("TP connection closed in destructor");
    }
}

// ============================================================================
// PUBLIC INTERFACE
// ============================================================================

void QuoteFeedHandler::run() {
    spdlog::info("Starting...");
    spdlog::info("Symbols: {}", fmt::join(symbols_, " "));
    
    // Connect to tickerplant
    if (!connectToTP()) {
        spdlog::warn("Shutdown before TP connection established");
        return;
    }
    
    // Main loop with reconnection
    while (running_) {
        try {
            runWebSocketLoop();
        } catch (const std::exception& e) {
            if (!running_) {
                spdlog::info("Connection closed during shutdown");
            } else {
                spdlog::error("Binance error: {}", e.what());
                spdlog::info("Will reconnect...");
                if (!sleepWithBackoff(binanceReconnectAttempt_++)) {
                    break;
                }
            }
        }
    }
    
    // Cleanup
    spdlog::info("Cleaning up...");
    if (tpHandle_ > 0) {
        kclose(tpHandle_);
        tpHandle_ = -1;
        spdlog::info("TP connection closed");
    }
    
    spdlog::info("Shutdown complete (processed {} messages)", fhSeqNo_);
}

void QuoteFeedHandler::stop() {
    spdlog::info("Stop requested");
    running_ = false;
}

// ============================================================================
// CONNECTION MANAGEMENT
// ============================================================================

std::string QuoteFeedHandler::buildDepthStreamPath() const {
    std::string path = "/stream?streams=";
    for (size_t i = 0; i < symbols_.size(); ++i) {
        if (i > 0) path += "/";
        path += symbols_[i] + "@depth";
    }
    return path;
}

bool QuoteFeedHandler::connectToTP() {
    int attempt = 0;
    while (running_) {
        spdlog::info("Connecting to TP on {}:{}...", tpHost_, tpPort_);
        
        int h = khpu((S)tpHost_.c_str(), tpPort_, (S)"");
        
        if (h > 0) {
            tpHandle_ = h;
            spdlog::info("Connected to TP (handle {})", h);
            return true;
        }
        
        spdlog::error("Failed to connect to TP");
        if (!sleepWithBackoff(attempt++)) {
            return false;
        }
    }
    return false;
}

bool QuoteFeedHandler::sleepWithBackoff(int attempt) {
    int delay = INITIAL_BACKOFF_MS;
    for (int i = 0; i < attempt && delay < MAX_BACKOFF_MS; ++i) {
        delay *= BACKOFF_MULTIPLIER;
    }
    delay = std::min(delay, MAX_BACKOFF_MS);
    
    spdlog::info("Waiting {}ms before reconnect...", delay);
    
    const int checkIntervalMs = 100;
    int slept = 0;
    while (slept < delay && running_) {
        std::this_thread::sleep_for(std::chrono::milliseconds(checkIntervalMs));
        slept += checkIntervalMs;
    }
    
    return running_;
}

void QuoteFeedHandler::resetAllBooks() {
    for (auto& [sym, state] : states_) {
        state.book.reset();
        state.deltaBuffer.clear();
        state.snapshotRequested = false;
    }
}

// ============================================================================
// WEBSOCKET LOOP
// ============================================================================

void QuoteFeedHandler::runWebSocketLoop() {
    std::string target = buildDepthStreamPath();
    spdlog::info("Connecting to Binance: {}{}", BINANCE_HOST, target);
    
    connState_ = "connecting";
    
    // Reset all books on reconnect
    resetAllBooks();
    
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
    
    spdlog::info("Connected to Binance ({} symbols)", symbols_.size());
    connState_ = "connected";
    
    // Reset backoff
    binanceReconnectAttempt_ = 0;
    
    // Health publish timer
    auto lastHealthPub = std::chrono::steady_clock::now();
    
    // Message loop
    while (running_) {
        beast::flat_buffer buffer;
        ws.read(buffer);
        
        if (!running_) break;
        
        auto recvTime = std::chrono::system_clock::now();
        long long fhRecvTimeUtcNs = std::chrono::duration_cast<std::chrono::nanoseconds>(
            recvTime.time_since_epoch()).count();
        
        // Update health: message received
        lastMsgTime_ = recvTime;
        ++msgsReceived_;
        
        std::string msg = beast::buffers_to_string(buffer.data());
        processMessage(msg, fhRecvTimeUtcNs);
        
        // Check publish timeouts
        checkPublishTimeouts(fhRecvTimeUtcNs);
        
        // Publish health every HEALTH_INTERVAL_SEC seconds
        auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration_cast<std::chrono::seconds>(now - lastHealthPub).count() >= HEALTH_INTERVAL_SEC) {
            publishHealth();
            lastHealthPub = now;
        }
    }
    
    connState_ = "disconnected";
    
    // Graceful close
    if (!running_) {
        try {
            ws.close(websocket::close_code::normal);
            spdlog::info("WebSocket closed gracefully");
        } catch (...) {
            // Ignore errors during shutdown
        }
    }
}

// ============================================================================
// MESSAGE PROCESSING
// ============================================================================

void QuoteFeedHandler::processMessage(const std::string& msg, long long fhRecvTimeUtcNs) {
    rapidjson::Document doc;
    doc.Parse(msg.c_str());
    if (!doc.IsObject()) return;
    
    // Combined stream format: {"stream":"btcusdt@depth","data":{...}}
    if (!doc.HasMember("data")) return;
    const auto& d = doc["data"];
    if (!d.IsObject()) return;
    
    // Extract symbol
    if (!d.HasMember("s")) return;
    std::string sym = d["s"].GetString();
    
    auto it = states_.find(sym);
    if (it == states_.end()) return;
    
    SymbolState& state = it->second;
    
    // Parse delta fields
    if (!d.HasMember("U") || !d.HasMember("u")) return;
    
    BufferedDelta delta;
    delta.firstUpdateId = d["U"].GetInt64();
    delta.finalUpdateId = d["u"].GetInt64();
    delta.eventTimeMs = d.HasMember("E") ? d["E"].GetInt64() : 0;
    
    // Parse bid updates
    if (d.HasMember("b") && d["b"].IsArray()) {
        const auto& bids = d["b"];
        for (rapidjson::SizeType i = 0; i < bids.Size(); ++i) {
            if (bids[i].IsArray() && bids[i].Size() >= 2) {
                PriceLevel lvl;
                lvl.price = std::stod(bids[i][0].GetString());
                lvl.qty = std::stod(bids[i][1].GetString());
                delta.bids.push_back(lvl);
            }
        }
    }
    
    // Parse ask updates
    if (d.HasMember("a") && d["a"].IsArray()) {
        const auto& asks = d["a"];
        for (rapidjson::SizeType i = 0; i < asks.Size(); ++i) {
            if (asks[i].IsArray() && asks[i].Size() >= 2) {
                PriceLevel lvl;
                lvl.price = std::stod(asks[i][0].GetString());
                lvl.qty = std::stod(asks[i][1].GetString());
                delta.asks.push_back(lvl);
            }
        }
    }
    
    // Handle based on book state
    handleDelta(state, delta, fhRecvTimeUtcNs);
}

void QuoteFeedHandler::handleDelta(SymbolState& state, const BufferedDelta& delta, long long fhRecvTimeUtcNs) {
    OrderBook& book = state.book;
    
    switch (book.state()) {
        case OrderBook::State::INIT:
            // Start buffering, request snapshot
            state.deltaBuffer.push_back(delta);
            if (!state.snapshotRequested) {
                state.snapshotRequested = true;
                requestSnapshot(state);
            }
            break;
            
        case OrderBook::State::SYNCING:
            // Try to apply delta to transition to VALID
            if (!book.applyDelta(delta.firstUpdateId, delta.finalUpdateId,
                                 delta.bids, delta.asks, delta.eventTimeMs)) {
                publishInvalid(state, fhRecvTimeUtcNs);
                book.reset();
                state.snapshotRequested = false;
            } else {
                if (book.isValid()) {
                    maybePublish(state, fhRecvTimeUtcNs);
                }
            }
            break;
            
        case OrderBook::State::VALID:
            // Apply delta directly
            if (!book.applyDelta(delta.firstUpdateId, delta.finalUpdateId,
                                 delta.bids, delta.asks, delta.eventTimeMs)) {
                publishInvalid(state, fhRecvTimeUtcNs);
                book.reset();
                state.deltaBuffer.clear();
                state.snapshotRequested = false;
            } else {
                maybePublish(state, fhRecvTimeUtcNs);
            }
            break;
            
        case OrderBook::State::INVALID:
            // Reset and start over
            book.reset();
            state.deltaBuffer.clear();
            state.snapshotRequested = false;
            break;
    }
}

// ============================================================================
// SNAPSHOT HANDLING
// ============================================================================

void QuoteFeedHandler::requestSnapshot(SymbolState& state) {
    spdlog::info("Requesting snapshot for {}", state.book.symbol());
    
    // Fetch snapshot (blocking)
    SnapshotData snapshot = restClient_.fetchSnapshot(state.book.symbol(), BOOK_DEPTH * 10);
    
    if (!snapshot.success) {
        spdlog::error("Snapshot failed: {}", snapshot.error);
        state.book.invalidate("Snapshot fetch failed");
        return;
    }
    
    // Apply snapshot
    state.book.applySnapshot(snapshot.lastUpdateId, snapshot.bids, snapshot.asks, 0);
    
    spdlog::debug("Applying {} buffered deltas", state.deltaBuffer.size());
    
    // Apply buffered deltas
    for (const auto& delta : state.deltaBuffer) {
        if (!state.book.applyDelta(delta.firstUpdateId, delta.finalUpdateId,
                                   delta.bids, delta.asks, delta.eventTimeMs)) {
            break;
        }
    }
    
    // Clear buffer
    state.deltaBuffer.clear();
    
    if (state.book.isValid()) {
        spdlog::info("Book {} is now VALID", state.book.symbol());
    }
}

// ============================================================================
// PUBLISHING
// ============================================================================

void QuoteFeedHandler::maybePublish(SymbolState& state, long long fhRecvTimeUtcNs) {
    ++fhSeqNo_;
    L1Quote quote = state.book.getL1(fhRecvTimeUtcNs, fhSeqNo_);
    
    if (state.publisher.shouldPublish(quote)) {
        publishL1(quote);
        state.publisher.recordPublish(quote);
    }
}

void QuoteFeedHandler::publishInvalid(SymbolState& state, long long fhRecvTimeUtcNs) {
    ++fhSeqNo_;
    L1Quote quote;
    quote.sym = state.book.symbol();
    quote.bid = {0.0, 0.0};
    quote.ask = {0.0, 0.0};
    quote.isValid = false;
    quote.fhRecvTimeUtcNs = fhRecvTimeUtcNs;
    quote.fhSeqNo = fhSeqNo_;
    
    publishL1(quote);
    state.publisher.recordPublish(quote);
    
    spdlog::warn("Published INVALID for {}", quote.sym);
}

void QuoteFeedHandler::publishL1(const L1Quote& quote) {
    // Build kdb+ row matching quote_binance schema
    K row = knk(10,
        ktj(-KP, quote.fhRecvTimeUtcNs - KDB_EPOCH_OFFSET_NS),
        ks((S)quote.sym.c_str()),
        kf(quote.bid.price),
        kf(quote.bid.qty),
        kf(quote.ask.price),
        kf(quote.ask.qty),
        kb(quote.isValid),
        kj(quote.exchEventTimeMs),
        kj(quote.fhRecvTimeUtcNs),
        kj(quote.fhSeqNo)
    );
    
    K result = k(-tpHandle_, (S)".u.upd", ks((S)"quote_binance"), row, (K)0);
    
    // Update health: message published
    lastPubTime_ = std::chrono::system_clock::now();
    ++msgsPublished_;
    
    // Check if TP connection died
    if (result == nullptr) {
        spdlog::error("TP connection lost, reconnecting...");
        connState_ = "reconnecting";
        kclose(tpHandle_);
        tpHandle_ = -1;
        if (connectToTP()) {
            // Resend to new connection
            k(-tpHandle_, (S)".u.upd", ks((S)"quote_binance"), row, (K)0);
        }
    }
}

void QuoteFeedHandler::publishHealth() {
    if (tpHandle_ <= 0) return;
    
    auto now = std::chrono::system_clock::now();
    
    // Calculate uptime
    long long uptimeSec = std::chrono::duration_cast<std::chrono::seconds>(
        now - startTime_).count();
    
    // Convert timestamps to kdb+ format
    auto toKdbTs = [](std::chrono::system_clock::time_point tp) -> long long {
        return std::chrono::duration_cast<std::chrono::nanoseconds>(
            tp.time_since_epoch()).count() - KDB_EPOCH_OFFSET_NS;
    };
    
    // Build health row (10 fields)
    K row = knk(10,
        ktj(-KP, toKdbTs(now)),                    // time
        ks((S)"quote_fh"),                          // handler
        ktj(-KP, toKdbTs(startTime_)),             // startTimeUtc
        kj(uptimeSec),                              // uptimeSec
        kj(msgsReceived_),                          // msgsReceived
        kj(msgsPublished_),                         // msgsPublished
        ktj(-KP, toKdbTs(lastMsgTime_)),           // lastMsgTimeUtc
        ktj(-KP, toKdbTs(lastPubTime_)),           // lastPubTimeUtc
        ks((S)connState_.c_str()),                  // connState
        ki(static_cast<int>(symbols_.size()))       // symbolCount
    );
    
    // Publish to TP (fire and forget)
    k(-tpHandle_, (S)".u.upd", ks((S)"health_feed_handler"), row, (K)0);
    
    spdlog::debug("Health published: uptime={}s msgs={}/{} state={}", 
        uptimeSec, msgsReceived_, msgsPublished_, connState_);
}

void QuoteFeedHandler::checkPublishTimeouts(long long fhRecvTimeUtcNs) {
    for (auto& [sym, state] : states_) {
        if (state.book.isValid()) {
            ++fhSeqNo_;
            L1Quote quote = state.book.getL1(fhRecvTimeUtcNs, fhSeqNo_);
            if (state.publisher.shouldPublish(quote)) {
                publishL1(quote);
                state.publisher.recordPublish(quote);
            }
        }
    }
}

// ============================================================================
// CONFIGURATION
// ============================================================================

#include "config.hpp"
#include "logger.hpp"

static const std::string DEFAULT_CONFIG_PATH = "config/quote_feed_handler.json";

// ============================================================================
// SIGNAL HANDLING
// ============================================================================

// Global pointer for signal handler access
static QuoteFeedHandler* g_handler = nullptr;

static void signalHandler(int signum) {
    const char* sigName = (signum == SIGINT) ? "SIGINT" : 
                          (signum == SIGTERM) ? "SIGTERM" : "UNKNOWN";
    spdlog::info("Received {} ({})", sigName, signum);
    
    if (g_handler) {
        g_handler->stop();
    }
}

// ============================================================================
// MAIN
// ============================================================================

int main(int argc, char* argv[]) {
    std::cout << "=== Binance Quote Feed Handler ===\n";
    
    // Determine config path (from argument or default)
    std::string configPath = DEFAULT_CONFIG_PATH;
    if (argc > 1) {
        configPath = argv[1];
    }
    
    // Load configuration
    FeedHandlerConfig config;
    if (!config.load(configPath)) {
        std::cerr << "Failed to load config, exiting\n";
        return 1;
    }
    
    if (config.symbols.empty()) {
        std::cerr << "No symbols configured, exiting\n";
        return 1;
    }
    
    // Initialize logger
    initLogger("Quote FH", config.logLevel, config.logFile);
    
    // Install signal handlers
    std::signal(SIGINT, signalHandler);
    std::signal(SIGTERM, signalHandler);
    spdlog::info("Signal handlers installed (Ctrl+C to shutdown)");
    
    // Create and run handler
    QuoteFeedHandler handler(config.symbols, config.tpHost, config.tpPort);
    g_handler = &handler;
    
    handler.run();
    
    g_handler = nullptr;
    spdlog::info("Exiting");
    shutdownLogger();
    return 0;
}
