#include <iostream>
#include "quote_handler.hpp"

const std::vector<std::string> SYMBOLS = {
    "btcusdt",
    "ethusdt"
};

int main() {
    std::cout << "Binance Quote Handler" << std::endl;
    std::cout << "Symbols: ";
    for (const auto& s : SYMBOLS) std::cout << s << " ";
    std::cout << std::endl;

    int tp = khpu((S)"localhost", 5010, (S)"");
    if (tp < 0) {
        std::cerr << "Failed to connect to TP on port 5010" << std::endl;
        return 1;
    }
    std::cout << "Connected to TP" << std::endl;

    QuoteHandler handler(SYMBOLS, tp);
    handler.run();

    return 0;
}