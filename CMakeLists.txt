cmake_minimum_required(VERSION 3.16)

project(binance_feed_handler LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(Threads REQUIRED)
find_package(OpenSSL REQUIRED)
find_package(Boost REQUIRED COMPONENTS system)

# Trade feed handler
add_executable(binance_feed_handler
    src/main.cpp
    src/feed_handler.cpp
)

target_include_directories(binance_feed_handler PRIVATE
    ${PROJECT_SOURCE_DIR}/third_party/kdb
)

target_link_libraries(binance_feed_handler
    ${PROJECT_SOURCE_DIR}/third_party/kdb/c.o
    Boost::system
    OpenSSL::SSL
    OpenSSL::Crypto
    Threads::Threads
)

# Quote feed handler
add_executable(binance_quote_handler
    src/quote_handler_main.cpp
)

target_include_directories(binance_quote_handler PRIVATE
    ${PROJECT_SOURCE_DIR}/third_party/kdb
)

target_link_libraries(binance_quote_handler
    ${PROJECT_SOURCE_DIR}/third_party/kdb/c.o
    Boost::system
    OpenSSL::SSL
    OpenSSL::Crypto
    Threads::Threads
)

# Snapshot test (optional, keep for debugging)
add_executable(test_snapshot
    src/test_snapshot.cpp
)

target_include_directories(test_snapshot PRIVATE
    ${PROJECT_SOURCE_DIR}/third_party/kdb
)

target_link_libraries(test_snapshot
    Boost::system
    OpenSSL::SSL
    OpenSSL::Crypto
    Threads::Threads
)