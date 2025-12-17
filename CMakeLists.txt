cmake_minimum_required(VERSION 3.16)
project(binance_feed_handler LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_executable(binance_feed_handler
  src/main.cpp
  src/e.o
)

target_include_directories(binance_feed_handler PRIVATE src)

# pthread is commonly required
target_link_libraries(binance_feed_handler PRIVATE pthread)
