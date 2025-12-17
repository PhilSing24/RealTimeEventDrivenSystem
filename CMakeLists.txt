# Minimum version of CMake required.
# Ensures consistent behaviour across machines and avoids legacy quirks.
cmake_minimum_required(VERSION 3.16)

# Defines the project name and the languages used.
# This name is used for generated build targets and metadata.
project(binance_feed_handler LANGUAGES CXX)

# Enforce use of C++17.
# Required for std::chrono, modern STL, and compatibility with Boost.Beast.
set(CMAKE_CXX_STANDARD 17)

# Makes C++17 mandatory (build fails if compiler cannot support it).
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Locate the system threading library (pthread on Linux).
# Required by Boost.Asio and generally by networking code.
find_package(Threads REQUIRED)

# Locate OpenSSL installation.
# Required for TLS support when connecting to Binance over wss://
find_package(OpenSSL REQUIRED)

# Locate Boost libraries.
# We only require Boost.System here (used by Boost.Asio / Beast).
find_package(Boost REQUIRED COMPONENTS system)

# Define the executable target and its source files.
# CMake will compile these and link them into a binary named "binance_feed_handler".
add_executable(binance_feed_handler
    src/main.cpp
    src/feed_handler.cpp
)

# Add include paths for header resolution.
# /usr/include is where rapidjson and system headers live on Ubuntu.
# (This is explicit for clarity; often optional.)
target_include_directories(binance_feed_handler PRIVATE
    /usr/include
)

# Link required libraries to the executable.
# Order does not usually matter in modern CMake.
target_link_libraries(binance_feed_handler
    Boost::system      # Required by Boost.Asio / Beast
    OpenSSL::SSL       # TLS layer
    OpenSSL::Crypto    # Cryptographic primitives
    Threads::Threads   # pthread support
)
