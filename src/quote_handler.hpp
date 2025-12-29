/**
 * @file quote_handler.hpp
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
 */

#ifndef QUOTE_HANDLER_HPP
#define QUOTE_HANDLER_HPP

#include <boost/beast/core.hpp>
#include <boost/beast/websocket.hpp>
#include <boost/beast/ssl.hpp>
#include <boost/asio/connect.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/ssl/context.hpp>

#include <rapidjson/document.h>

#include <string>
#include <vector>
#include <unordered_map>
#include <deque>
#include <chrono>
#include <iostream>
#include <thread>

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

// Epoch offset for kdb+ timestamps
const long long KDB_EPOCH_OFFSET_NS_Q = 946684800000000000LL;

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
 * @brief Quote handler - manages depth streams and L1 publication
 */
class QuoteHandler {
public:
    QuoteHandler(const std::vector<std::string>& symbols, int tpHandle)
        : symbols_(symbols), tp_(tpHandle) {
        // Initialize per-symbol state
        for (const auto& sym : symbols) {
            // Convert to uppercase for internal use
            std::string upper = sym;
            for (auto& c : upper) c = std::toupper(c);
            states_.emplace(upper, SymbolState(upper));
        }
    }

    /**
     * @brief Run the quote handler (blocking)
     * 
     * Connects to Binance, processes depth updates, publishes L1.
     */
    void run() {
        const std::string host = "stream.binance.com";
        const std::string port = "9443";
        const std::string target = buildDepthStreamPath();

        int reconnectAttempt = 0;

        while (true) {
            try {
                std::cout << "[QH] Connecting to depth stream: " << target << std::endl;

                // Reset all books on reconnect
                for (auto& [sym, state] : states_) {
                    state.book.reset();
                    state.deltaBuffer.clear();
                    state.snapshotRequested = false;
                }

                // Initialize ASIO and SSL
                net::io_context ioc;
                ssl::context ctx{ssl::context::tlsv12_client};
                ctx.set_default_verify_paths();

                tcp::resolver resolver{ioc};
                websocket::stream<beast::ssl_stream<tcp::socket>> ws{ioc, ctx};

                auto const results = resolver.resolve(host, port);
                net::connect(ws.next_layer().next_layer(), results.begin(), results.end());
                ws.next_layer().handshake(ssl::stream_base::client);
                ws.handshake(host, target);

                std::cout << "[QH] Connected to Binance depth stream" << std::endl;
                reconnectAttempt = 0;

                // Message loop
                for (;;) {
                    beast::flat_buffer buffer;
                    ws.read(buffer);

                    auto recvTime = std::chrono::system_clock::now();
                    long long fhRecvTimeUtcNs = std::chrono::duration_cast<std::chrono::nanoseconds>(
                        recvTime.time_since_epoch()).count();

                    std::string msg = beast::buffers_to_string(buffer.data());
                    processMessage(msg, fhRecvTimeUtcNs);

                    // Check publish timeouts for all symbols
                    checkPublishTimeouts(fhRecvTimeUtcNs);
                }

            } catch (const std::exception& e) {
                std::cerr << "[QH] Error: " << e.what() << std::endl;
                sleepWithBackoff(reconnectAttempt++);
            }
        }
    }

private:
    std::vector<std::string> symbols_;
    std::unordered_map<std::string, SymbolState> states_;
    int tp_;
    long long fhSeqNo_ = 0;
    RestClient restClient_;

    /**
     * @brief Build WebSocket path for depth streams
     */
    std::string buildDepthStreamPath() const {
        std::string path = "/stream?streams=";
        for (size_t i = 0; i < symbols_.size(); ++i) {
            if (i > 0) path += "/";
            path += symbols_[i] + "@depth";
        }
        return path;
    }

    /**
     * @brief Process incoming WebSocket message
     */
    void processMessage(const std::string& msg, long long fhRecvTimeUtcNs) {
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
        // e: event type ("depthUpdate")
        // E: event time (ms)
        // U: first update ID
        // u: final update ID
        // b: bids [[price, qty], ...]
        // a: asks [[price, qty], ...]

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

    /**
     * @brief Handle delta based on current book state
     */
    
    void handleDelta(SymbolState& state, const BufferedDelta& delta, long long fhRecvTimeUtcNs) {
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
                    // Failed - might be stale or gap
                    // If stale, applyDelta returns true, so this is a gap
                    publishInvalid(state, fhRecvTimeUtcNs);
                    book.reset();
                    state.snapshotRequested = false;
                } else {
                    // Check if now valid and should publish
                    if (book.isValid()) {
                        maybePublish(state, fhRecvTimeUtcNs);
                    }
                }
                break;

            case OrderBook::State::VALID:
                // Apply delta directly
                if (!book.applyDelta(delta.firstUpdateId, delta.finalUpdateId,
                                     delta.bids, delta.asks, delta.eventTimeMs)) {
                    // Sequence gap - publish invalid, then rebuild
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

    /**
     * @brief Request and apply snapshot
     */
    void requestSnapshot(SymbolState& state) {
        std::cout << "[QH] Requesting snapshot for " << state.book.symbol() << std::endl;

        // Fetch snapshot (blocking)
        SnapshotData snapshot = restClient_.fetchSnapshot(state.book.symbol(), BOOK_DEPTH * 10);

        if (!snapshot.success) {
            std::cerr << "[QH] Snapshot failed: " << snapshot.error << std::endl;
            state.book.invalidate("Snapshot fetch failed");
            return;
        }

        // Apply snapshot
        state.book.applySnapshot(snapshot.lastUpdateId, snapshot.bids, snapshot.asks, 0);

        std::cout << "[QH] Applying " << state.deltaBuffer.size() << " buffered deltas" << std::endl;

        // Apply buffered deltas
        for (const auto& delta : state.deltaBuffer) {
            if (!state.book.applyDelta(delta.firstUpdateId, delta.finalUpdateId,
                                       delta.bids, delta.asks, delta.eventTimeMs)) {
                // If any delta fails, keep in SYNCING or go INVALID
                // applyDelta handles state transitions
                break;
            }
        }

        // Clear buffer
        state.deltaBuffer.clear();

        if (state.book.isValid()) {
            std::cout << "[QH] Book " << state.book.symbol() << " is now VALID" << std::endl;
        }
    }

    /**
     * @brief Check if should publish and do it
     */
    void maybePublish(SymbolState& state, long long fhRecvTimeUtcNs) {
        ++fhSeqNo_;
        L1Quote quote = state.book.getL1(fhRecvTimeUtcNs, fhSeqNo_);

        if (state.publisher.shouldPublish(quote)) {
            publishL1(quote);
            state.publisher.recordPublish(quote);
        }
    }

    /**
     * @brief Publish invalid state (once)
     */
    void publishInvalid(SymbolState& state, long long fhRecvTimeUtcNs) {
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

        std::cout << "[QH] Published INVALID for " << quote.sym << std::endl;
    }

    /**
     * @brief Publish L1 quote to kdb+
     */
    void publishL1(const L1Quote& quote) {
        // Build kdb+ row matching quote_binance schema
        K row = knk(10,
            ktj(-KP, quote.fhRecvTimeUtcNs - KDB_EPOCH_OFFSET_NS_Q),  // time
            ks((S)quote.sym.c_str()),                                 // sym
            kf(quote.bid.price),                                      // bidPx
            kf(quote.bid.qty),                                        // bidQty
            kf(quote.ask.price),                                      // askPx
            kf(quote.ask.qty),                                        // askQty
            kb(quote.isValid),                                        // isValid
            kj(quote.exchEventTimeMs),                                // exchEventTimeMs
            kj(quote.fhRecvTimeUtcNs),                                // fhRecvTimeUtcNs
            kj(quote.fhSeqNo)                                         // fhSeqNo
        );

        K result = k(-tp_, (S)".u.upd", ks((S)"quote_binance"), row, (K)0);

        if (result == nullptr) {
            std::cerr << "[QH] TP connection lost" << std::endl;
            // TODO: reconnect logic
        }
    }

    /**
     * @brief Check publish timeouts for all symbols
     */
    void checkPublishTimeouts(long long fhRecvTimeUtcNs) {
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

    /**
     * @brief Sleep with exponential backoff
     */
    void sleepWithBackoff(int attempt) {
        int delay = 1000;
        for (int i = 0; i < attempt && delay < 8000; ++i) {
            delay *= 2;
        }
        delay = std::min(delay, 8000);
        std::cout << "[QH] Waiting " << delay << "ms before reconnect..." << std::endl;
        std::this_thread::sleep_for(std::chrono::milliseconds(delay));
    }
};

#endif // QUOTE_HANDLER_HPP