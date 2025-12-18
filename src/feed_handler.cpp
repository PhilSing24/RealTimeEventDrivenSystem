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

    // ---- Connect to tickerplant ----
    int tp = khpu((S)"localhost", 5010, (S)"");
    if (tp < 0) {
        std::cerr << "Failed to connect to tickerplant\n";
        return 1;
    }

    // ---- Sequence number: monotonically increasing per FH instance ----
    long long fhSeqNo = 0;

    for (;;) {
        beast::flat_buffer buffer;
        ws.read(buffer);

        // ---- Wall-clock timestamp: for cross-process correlation ----
        auto recvWall = std::chrono::system_clock::now();
        long long fhRecvTimeUtcNs =
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                recvWall.time_since_epoch()).count();

        // ---- Monotonic timestamp: start of parse/normalise ----
        auto parseStart = std::chrono::steady_clock::now();

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

        // ---- Monotonic timestamp: end of parse/normalise ----
        auto parseEnd = std::chrono::steady_clock::now();
        long long fhParseUs = std::chrono::duration_cast<std::chrono::microseconds>(
            parseEnd - parseStart).count();

        // ---- Increment sequence number ----
        ++fhSeqNo;

        // ---- Build kdb row (this is "send preparation") ----
        // Row ordered to match table schema in tp.q
        K row = knk(12,
            ktj(-KP, fhRecvTimeUtcNs),       // time (placeholder; TP may overwrite)
            ks((S)sym),                       // sym
            kj(tradeId),                      // tradeId
            kf(price),                        // price
            kf(qty),                          // qty
            kb(buyerIsMaker),                 // buyerIsMaker
            kj(exchEventTimeMs),              // exchEventTimeMs
            kj(exchTradeTimeMs),              // exchTradeTimeMs
            kj(fhRecvTimeUtcNs),              // fhRecvTimeUtcNs
            kj(fhParseUs),                    // fhParseUs
            kj(0LL),                          // fhSendUs (placeholder)
            kj(fhSeqNo)                       // fhSeqNo
        );

        // ---- Monotonic timestamp: end of send preparation ----
        auto sendEnd = std::chrono::steady_clock::now();
        long long fhSendUs = std::chrono::duration_cast<std::chrono::microseconds>(
            sendEnd - parseEnd).count();

        // Update fhSendUs in the row (index 10)
        kK(row)[10]->j = fhSendUs;

        std::cout
            << "sym=" << sym
            << " tradeId=" << tradeId
            << " price=" << price
            << " qty=" << qty
            << " fhParseUs=" << fhParseUs
            << " fhSendUs=" << fhSendUs
            << " fhSeqNo=" << fhSeqNo
            << std::endl;

        // ---- IPC send to tickerplant ----
        k(-tp, (S)".u.upd", ks((S)"trade_binance"), row, (K)0);
    }

    return 0;
}


