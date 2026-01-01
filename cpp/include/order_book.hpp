#ifndef ORDER_BOOK_HPP
#define ORDER_BOOK_HPP

#include <string>
#include <vector>
#include <algorithm>
#include <chrono>
#include <iostream>

constexpr int BOOK_DEPTH = 5;
constexpr int PUBLISH_TIMEOUT_MS = 50;

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

struct L1Quote {
    std::string sym;
    PriceLevel bid;
    PriceLevel ask;
    bool isValid = false;
    long long exchEventTimeMs = 0;
    long long fhRecvTimeUtcNs = 0;
    long long fhSeqNo = 0;
};

class OrderBook {
public:
    enum class State { 
        INIT,
        SYNCING,
        VALID,
        INVALID
    };

    explicit OrderBook(const std::string& symbol) 
        : sym_(symbol), state_(State::INIT) {
        bids_.reserve(BOOK_DEPTH);
        asks_.reserve(BOOK_DEPTH);
    }

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

    void applySnapshot(long long lastUpdateId,
                       const std::vector<PriceLevel>& bids,
                       const std::vector<PriceLevel>& asks,
                       long long exchTimeMs) {
        bids_.clear();
        asks_.clear();
        
        for (size_t i = 0; i < bids.size() && i < BOOK_DEPTH; ++i) {
            bids_.push_back(bids[i]);
        }
        
        for (size_t i = 0; i < asks.size() && i < BOOK_DEPTH; ++i) {
            asks_.push_back(asks[i]);
        }
        
        snapshotUpdateId_ = lastUpdateId;
        lastUpdateId_ = lastUpdateId;
        exchEventTimeMs_ = exchTimeMs;
        state_ = State::SYNCING;
    }

    bool applyDelta(long long firstUpdateId, 
                    long long finalUpdateId,
                    const std::vector<PriceLevel>& bidUpdates,
                    const std::vector<PriceLevel>& askUpdates,
                    long long exchTimeMs) {
        
        if (state_ == State::SYNCING) {
            if (firstUpdateId > snapshotUpdateId_ + 1) {
                invalidate("Snapshot too old");
                return false;
            }
            if (finalUpdateId < snapshotUpdateId_ + 1) {
                return true;
            }
            state_ = State::VALID;
        } 
        else if (state_ == State::VALID) {
            if (firstUpdateId != lastUpdateId_ + 1) {
                invalidate("Sequence gap");
                return false;
            }
        }
        else {
            return false;
        }
        
        for (const auto& upd : bidUpdates) {
            applyLevelUpdate(bids_, upd, true);
        }
        
        for (const auto& upd : askUpdates) {
            applyLevelUpdate(asks_, upd, false);
        }
        
        lastUpdateId_ = finalUpdateId;
        exchEventTimeMs_ = exchTimeMs;
        return true;
    }

    void invalidate(const char* reason) {
        std::cerr << "[BOOK] " << sym_ << " invalidated: " << reason << std::endl;
        state_ = State::INVALID;
    }

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
    
    std::vector<PriceLevel> bids_;
    std::vector<PriceLevel> asks_;
    
    long long lastUpdateId_ = 0;
    long long snapshotUpdateId_ = 0;
    long long exchEventTimeMs_ = 0;

    void applyLevelUpdate(std::vector<PriceLevel>& side, 
                          const PriceLevel& update,
                          bool isBid) {
        auto it = std::find_if(side.begin(), side.end(),
            [&](const PriceLevel& lvl) { return lvl.price == update.price; });
        
        if (update.qty == 0.0) {
            if (it != side.end()) {
                side.erase(it);
            }
        } else {
            if (it != side.end()) {
                it->qty = update.qty;
            } else {
                auto insertPos = std::find_if(side.begin(), side.end(),
                    [&](const PriceLevel& lvl) {
                        return isBid ? (update.price > lvl.price) 
                                     : (update.price < lvl.price);
                    });
                side.insert(insertPos, update);
                
                if (side.size() > BOOK_DEPTH) {
                    side.pop_back();
                }
            }
        }
    }
};

class L1Publisher {
public:
    explicit L1Publisher(const std::string& symbol) : sym_(symbol) {}

    bool shouldPublish(const L1Quote& current) {
        auto now = std::chrono::steady_clock::now();
        
        if (!hasPublished_) {
            return true;
        }
        
        if (current.isValid != lastPublished_.isValid) {
            return true;
        }
        
        if (!current.isValid) {
            return false;
        }
        
        if (current.bid != lastPublished_.bid || 
            current.ask != lastPublished_.ask) {
            return true;
        }
        
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            now - lastPublishTime_).count();
        if (elapsed >= PUBLISH_TIMEOUT_MS) {
            return true;
        }
        
        return false;
    }

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

#endif