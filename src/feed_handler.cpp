#include <boost/beast/core.hpp>
#include <boost/beast/websocket.hpp>
#include <boost/beast/ssl.hpp>
#include <boost/asio/connect.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/ssl/context.hpp>

#include <rapidjson/document.h>

#include <iostream>
#include <string>

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

    std::cout << "Connected to Binance trade stream" << std::endl;

    for (;;) {
        beast::flat_buffer buffer;
        ws.read(buffer);

        auto fh_recv_wall_ns =
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::system_clock::now().time_since_epoch()
            ).count();

        auto fh_recv_mono_ns =
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now().time_since_epoch()
            ).count();

        auto msg = beast::buffers_to_string(buffer.data());

        rapidjson::Document d;
        d.Parse(msg.c_str());
        if (d.HasParseError()) {
            std::cerr << "JSON parse error\n";
            continue;
        }

        // Handle combined stream envelope
        const rapidjson::Value* payload = &d;
        if (d.HasMember("data")) {
            payload = &d["data"];
        }

        if (!payload->IsObject()) continue;

        const auto& obj = *payload;

        std::string symbol = obj["s"].GetString();
        long tradeId = obj["t"].GetInt64();
        double price = std::stod(obj["p"].GetString());
        double qty = std::stod(obj["q"].GetString());
        long tradeTimeMs = obj["T"].GetInt64();

        std::cout
            << "symbol=" << symbol
            << " tradeId=" << tradeId
            << " price=" << price
            << " qty=" << qty
            << " exchTradeTimeMs=" << tradeTimeMs
            << " fhRecvWallNs=" << fh_recv_wall_ns
            << " fhRecvMonoNs=" << fh_recv_mono_ns
            << std::endl;
    }

    return 0;
}
