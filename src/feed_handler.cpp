#include <boost/beast/core.hpp>
#include <boost/beast/websocket.hpp>
#include <boost/beast/ssl.hpp>
#include <boost/asio/connect.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/ssl/context.hpp>

#include <rapidjson/document.h>

#include <iostream>
#include <string>
#include <chrono>

extern "C" {
#include "k.h"
}

namespace beast = boost::beast;
namespace websocket = beast::websocket;
namespace net = boost::asio;
namespace ssl = net::ssl;
using tcp = net::ip::tcp;

int run_feed_handler() {
    const std::string host = "stream.binance.com";
    const std::string port = "9443";
    const std::string target = "/ws/btcusdt@trade";

    net::io_context ioc;
    ssl::context ctx{ssl::context::tlsv12_client};
    ctx.set_default_verify_paths();

    tcp::resolver resolver{ioc};
    websocket::stream<beast::ssl_stream<tcp::socket>> ws{ioc, ctx};

    auto const results = resolver.resolve(host, port);
    net::connect(ws.next_layer().next_layer(), results.begin(), results.end());
    ws.next_layer().handshake(ssl::stream_base::client);
    ws.handshake(host, target);

    std::cout << "Connected to Binance trade stream\n";

    // ---- connect to tickerplant ----
    int tp = khpu((S)"localhost", 5010, (S)"");
    if (tp < 0) {
        std::cerr << "Failed to connect to tickerplant\n";
        return 1;
    }

    for (;;) {
        beast::flat_buffer buffer;
        ws.read(buffer);

        auto recvWall = std::chrono::system_clock::now();
        long long fhRecvTimeUtcNs =
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                recvWall.time_since_epoch()).count();

        std::string msg = beast::buffers_to_string(buffer.data());

        rapidjson::Document d;
        d.Parse(msg.c_str());
        if (!d.IsObject()) continue;

        if (!d.HasMember("s")) continue;

        const char* sym = d["s"].GetString();
        long long tradeId = d["t"].GetInt64();
        double price = std::stod(d["p"].GetString());
        double qty = std::stod(d["q"].GetString());
        bool buyerIsMaker = d["m"].GetBool();
        long long exchEventTimeMs = d["E"].GetInt64();
        long long exchTradeTimeMs = d["T"].GetInt64();

        std::cout
            << "symbol=" << sym
            << " tradeId=" << tradeId
            << " price=" << price
            << " qty=" << qty
            << std::endl;

        // build kdb row (ordered to match table schema)
        K row = knk(9,
            ktj(-KP, fhRecvTimeUtcNs),     // time (placeholder, TP overwrites if desired)
            ks((S)sym),
            kj(tradeId),
            kf(price),
            kf(qty),
            kb(buyerIsMaker),
            kj(exchEventTimeMs),
            kj(exchTradeTimeMs),
            kj(fhRecvTimeUtcNs)
        );

        k(tp, (S)".u.upd", ks((S)"trade_binance"), row, (K)0);
    }

    return 0;
}


