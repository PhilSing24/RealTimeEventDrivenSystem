/**
 * @file order_book.hpp
 * @brief L-N Order Book with validity state machine
 * 
 * Maintains a depth-configurable order book with:
 * - Sorted price levels (bids high→low, asks low→high)
 * - Sequence tracking for gap detection
 * - Validity state machine (INIT → SYNCING → VALID ↔ INVALID)
 * - L1 extraction for publication
 * 
 * Design principles:
 * - Internal book is L-N (configurable depth)
 * - Publication is L1 only (initially)
 * - Never publish invalid state as valid
 * - Single writer, no concurrent mutation
 */

#ifndef ORDER_BOOK_HPP
#define ORDER_BOOK_HPP

#include <string>
#include <vector>
#include <algorithm>
#include <chrono>

// Configurable book depth
constexpr int BOOK_DEPTH = 5;

// Publication timeout (ms)
constexpr int PUBLISH_TIMEOUT_MS = 50;

/**
 * @brief Single price level in the book
 */
struct PriceLevel {
    double price = 0.0;
    double qty = 0.0;
    
    bool operator==(const PriceLevel& other) const {
        return price == other.price && qty == other.qty;
    }
    
    bool operator!=(const PriceLevel& other) const {
        return !(*this == other);
    }
};

/**
 * @brief L1 quote snapshot for publication
 */
struct L1Quote {
    std::string sym;
    PriceLevel bid;
    PriceLevel ask;
    bool isValid = false;
    long long exchEventTimeMs = 0;
    long long fhRecvTimeUtcNs = 0;
    long long fhSeqNo = 0;
};

/**
 * @brief Order book with validity state machine
 */
class OrderBook {
public:
    /**
     * @brief Book validity states
     * 
     * State transitions:
     *   INIT → SYNCING (snapshot requested)
     *   SYNCING → VALID (snapshot applied, deltas caught up)
     *   SYNCING → INVALID (sequence gap during sync)
     *   VALID → VALID (delta applied successfully)
     *   VALID → INVALID (sequence gap detected)
     *   INVALID → INIT (trigger rebuild)
     */
    enum class State { 
        INIT,      // No data yet
        SYNCING,   // Snapshot received, applying buffered deltas
        VALID,     // Book is consistent and publishable
        INVALID    // Sequence gap or error, must rebuild
    };

    explicit OrderBook(const std::string& symbol) 
        : sym_(symbol), state_(State::INIT) {
        bids_.reserve(BOOK_DEPTH);
        asks_.reserve(BOOK_DEPTH);
    }

    // ---- Accessors ----
    
    const std::string& symbol() const { return sym_; }
    State state() const { return state_; }
    bool isValid() const { return state_ == State::VALID; }
    
    PriceLevel bestBid() const { 
        return bids_.empty() ? PriceLevel{0.0, 0.0} : bids_[0]; 
    }
    
    PriceLevel bestAsk() const { 
        return asks_.empty() ? PriceLevel{0.0, 0.0} : asks_[0]; 
    }
    
    long long lastUpdateId() const { return lastUpdateId_; }
    
    /**
     * @brief Get L1 quote for publication
     */
    L1Quote getL1(long long fhRecvTimeUtcNs, long long fhSeqNo) const {
        L1Quote q;
        q.sym = sym_;
        q.bid = bestBid();
        q.ask = bestAsk();
        q.isValid = isValid();
        q.exchEventTimeMs = exchEventTimeMs_;
        q.fhRecvTimeUtcNs = fhRecvTimeUtcNs;
        q.fhSeqNo = fhSeqNo;
        return q;
    }

    // ---- State Machine ----
    
    /**
     * @brief Apply REST snapshot
     * 
     * @param lastUpdateId Snapshot sequence number
     * @param bids Bid levels (price, qty pairs)
     * @param asks Ask levels (price, qty pairs)
     * @param exchTimeMs Exchange timestamp
     */
    void applySnapshot(long long lastUpdateId,
                       const std::vector<PriceLevel>& bids,
                       const std::vector<PriceLevel>& asks,
                       long long exchTimeMs) {
        // Clear existing book
        bids_.clear();
        asks_.clear();
        
        // Copy up to BOOK_DEPTH levels
        // Bids should already be sorted high→low from exchange
        for (size_t i = 0; i < bids.size() && i < BOOK_DEPTH; ++i) {
            bids_.push_back(bids[i]);
        }
        
        // Asks should already be sorted low→high from exchange
        for (size_t i = 0; i < asks.size() && i < BOOK_DEPTH; ++i) {
            asks_.push_back(asks[i]);
        }
        
        snapshotUpdateId_ = lastUpdateId;
        lastUpdateId_ = lastUpdateId;
        exchEventTimeMs_ = exchTimeMs;
        state_ = State::SYNCING;
    }

    /**
     * @brief Apply depth delta update
     * 
     * Binance depth update contains:
     * - U: first update ID in event
     * - u: final update ID in event
     * - b: bids to update
     * - a: asks to update
     * 
     * Sequencing rules:
     * - First delta after snapshot: U <= snapshotUpdateId+1 <= u
     * - Subsequent deltas: U == lastUpdateId + 1
     * 
     * @return true if applied successfully, false if sequence gap
     */
    bool applyDelta(long long firstUpdateId, 
                    long long finalUpdateId,
                    const std::vector<PriceLevel>& bidUpdates,
                    const std::vector<PriceLevel>& askUpdates,
                    long long exchTimeMs) {
        
        // Sequence validation
        if (state_ == State::SYNCING) {
            // First delta after snapshot
            // Must satisfy: U <= snapshotUpdateId+1 <= u
            if (firstUpdateId > snapshotUpdateId_ + 1) {
                // Gap - snapshot too old
                invalidate("Snapshot too old");
                return false;
            }
            if (finalUpdateId < snapshotUpdateId_ + 1) {
                // Stale delta - skip but don't invalidate
                return true;
            }
            // Valid first delta, transition to VALID
            state_ = State::VALID;
        } 
        else if (state_ == State::VALID) {
            // Subsequent deltas: U == lastUpdateId + 1
            if (firstUpdateId != lastUpdateId_ + 1) {
                invalidate("Sequence gap");
                return false;
            }
        }
        else {
            // INIT or INVALID - shouldn't receive deltas
            return false;
        }
        
        // Apply bid updates
        for (const auto& upd : bidUpdates) {
            applyLevelUpdate(bids_, upd, true);
        }
        
        // Apply ask updates
        for (const auto& upd : askUpdates) {
            applyLevelUpdate(asks_, upd, false);
        }
        
        lastUpdateId_ = finalUpdateId;
        exchEventTimeMs_ = exchTimeMs;
        return true;
    }

    /**
     * @brief Invalidate book (sequence gap or error)
     */
    void invalidate(const char* reason) {
        std::cerr << "[BOOK] " << sym_ << " invalidated: " << reason << std::endl;
        state_ = State::INVALID;
    }

    /**
     * @brief Reset to INIT state for rebuild
     */
    void reset() {
        bids_.clear();
        asks_.clear();
        lastUpdateId_ = 0;
        snapshotUpdateId_ = 0;
        state_ = State::INIT;
    }

private:
    std::string sym_;
    State state_;
    
    std::vector<PriceLevel> bids_;  // Sorted high→low
    std::vector<PriceLevel> asks_;  // Sorted low→high
    
    long long lastUpdateId_ = 0;
    long long snapshotUpdateId_ = 0;
    long long exchEventTimeMs_ = 0;

    /**
     * @brief Apply single level update to a side
     * 
     * Binance rules:
     * - qty == 0 means remove level
     * - qty > 0 means add/update level
     * 
     * @param side The book side (bids or asks)
     * @param update Price/qty update
     * @param isBid True for bids (high→low), false for asks (low→high)
     */
    void applyLevelUpdate(std::vector<PriceLevel>& side, 
                          const PriceLevel& update,
                          bool isBid) {
        // Find existing level at this price
        auto it = std::find_if(side.begin(), side.end(),
            [&](const PriceLevel& lvl) { return lvl.price == update.price; });
        
        if (update.qty == 0.0) {
            // Remove level
            if (it != side.end()) {
                side.erase(it);
            }
        } else {
            if (it != side.end()) {
                // Update existing level
                it->qty = update.qty;
            } else {
                // Insert new level in sorted position
                auto insertPos = std::find_if(side.begin(), side.end(),
                    [&](const PriceLevel& lvl) {
                        return isBid ? (update.price > lvl.price) 
                                     : (update.price < lvl.price);
                    });
                side.insert(insertPos, update);
                
                // Trim to BOOK_DEPTH
                if (side.size() > BOOK_DEPTH) {
                    side.pop_back();
                }
            }
        }
    }
};

/**
 * @brief Tracks L1 state for publication decisions
 */
class L1Publisher {
public:
    explicit L1Publisher(const std::string& symbol) : sym_(symbol) {}

    /**
     * @brief Check if we should publish
     * 
     * Publish when:
     * 1. Best bid price or size changes
     * 2. Best ask price or size changes  
     * 3. Validity changes
     * 4. Timeout exceeded (50ms)
     * 
     * @param current Current L1 quote
     * @return true if should publish
     */
    bool shouldPublish(const L1Quote& current) {
        auto now = std::chrono::steady_clock::now();
        
        // First update ever
        if (!hasPublished_) {
            return true;
        }
        
        // Validity change
        if (current.isValid != lastPublished_.isValid) {
            return true;
        }
        
        // If invalid, only publish once (already handled above)
        if (!current.isValid) {
            return false;
        }
        
        // Price or size change
        if (current.bid != lastPublished_.bid || 
            current.ask != lastPublished_.ask) {
            return true;
        }
        
        // Timeout
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            now - lastPublishTime_).count();
        if (elapsed >= PUBLISH_TIMEOUT_MS) {
            return true;
        }
        
        return false;
    }

    /**
     * @brief Record that we published
     */
    void recordPublish(const L1Quote& quote) {
        lastPublished_ = quote;
        lastPublishTime_ = std::chrono::steady_clock::now();
        hasPublished_ = true;
    }

private:
    std::string sym_;
    L1Quote lastPublished_;
    std::chrono::steady_clock::time_point lastPublishTime_;
    bool hasPublished_ = false;
};

#endif // ORDER_BOOK_HPP