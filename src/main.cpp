#include <iostream>

extern "C" {
#include "k.h"
}

int main() {
  std::cout << "binance_feed_handler: build OK" << std::endl;
  return 0;
}
