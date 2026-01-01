/**
 * main.cpp - Entry point for Binance Feed Handler
 */

 #include <iostream> // Includes the C++ Standard Library I/O stream header.

int run_feed_handler();

int main() {
    try {
        return run_feed_handler();
    } catch (const std::exception& e) {
        std::cerr << "Fatal error: " << e.what() << std::endl;
        return 1;
    }
}