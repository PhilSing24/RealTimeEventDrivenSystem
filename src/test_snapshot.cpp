/**
 * @file test_snapshot.cpp
 * @brief Test REST snapshot fetch and OrderBook initialization
 */

#include <iostream>
#include "rest_client.hpp"
#include "order_book.hpp"

int main() {
    std::cout << "=== Phase 1 Test: REST Snapshot + OrderBook ===" << std::endl;

    // Create REST client
    RestClient rest;

    // Fetch BTCUSDT snapshot
    SnapshotData snapshot = rest.fetchSnapshot("BTCUSDT", BOOK_DEPTH);

    if (!snapshot.success) {
        std::cerr << "Failed to fetch snapshot: " << snapshot.error << std::endl;
        return 1;
    }

    // Create OrderBook and apply snapshot
    OrderBook book("BTCUSDT");
    std::cout << "\nBook state before: " << static_cast<int>(book.state()) << std::endl;

    // Apply snapshot (exchTimeMs = 0 for test, real impl gets from depth stream)
    book.applySnapshot(snapshot.lastUpdateId, snapshot.bids, snapshot.asks, 0);

    std::cout << "Book state after: " << static_cast<int>(book.state()) << std::endl;
    std::cout << "Last update ID: " << book.lastUpdateId() << std::endl;

    // Display L1
    auto bid = book.bestBid();
    auto ask = book.bestAsk();
    std::cout << "\n=== L1 Quote ===" << std::endl;
    std::cout << "Best Bid: " << bid.price << " @ " << bid.qty << std::endl;
    std::cout << "Best Ask: " << ask.price << " @ " << ask.qty << std::endl;
    std::cout << "Spread: " << (ask.price - bid.price) << std::endl;
    std::cout << "Valid: " << (book.isValid() ? "NO (need delta)" : "NO (SYNCING)") << std::endl;

    // Test L1Quote generation
    L1Quote l1 = book.getL1(123456789, 1);
    std::cout << "\nL1Quote struct:" << std::endl;
    std::cout << "  sym: " << l1.sym << std::endl;
    std::cout << "  bid: " << l1.bid.price << " @ " << l1.bid.qty << std::endl;
    std::cout << "  ask: " << l1.ask.price << " @ " << l1.ask.qty << std::endl;
    std::cout << "  isValid: " << l1.isValid << std::endl;

    std::cout << "\n=== Phase 1 Test PASSED ===" << std::endl;
    return 0;
}