cmake_minimum_required(VERSION 3.16)

project(binance_feed_handler LANGUAGES CXX)

# -------------------------------------------------------------------
# C++ standard
# -------------------------------------------------------------------
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# -------------------------------------------------------------------
# Dependencies
# -------------------------------------------------------------------
find_package(Threads REQUIRED)
find_package(OpenSSL REQUIRED)
find_package(Boost REQUIRED COMPONENTS system)

# -------------------------------------------------------------------
# Executable
# -------------------------------------------------------------------
add_executable(binance_feed_handler
    src/main.cpp
    src/feed_handler.cpp
)

# -------------------------------------------------------------------
# Include paths
# -------------------------------------------------------------------
target_include_directories(binance_feed_handler PRIVATE
    ${PROJECT_SOURCE_DIR}/third_party/kdb
)

# -------------------------------------------------------------------
# Link libraries
# -------------------------------------------------------------------
target_link_libraries(binance_feed_handler
    ${PROJECT_SOURCE_DIR}/third_party/kdb/c.o
    Boost::system
    OpenSSL::SSL
    OpenSSL::Crypto
    Threads::Threads
)
