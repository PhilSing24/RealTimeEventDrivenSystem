/**
 * main.cpp - Entry point for Binance Feed Handler
 * 
 * Delegates to run_feed_handler() in feed_handler.cpp.
 * Top-level exception handler ensures clean exit on fatal errors.
 */
#include <iostream>

int run_feed_handler();

int main() {
    try {
        return run_feed_handler();
    } catch (const std::exception& e) {
        std::cerr << "Fatal error: " << e.what() << std::endl;
        return 1;
    }
}