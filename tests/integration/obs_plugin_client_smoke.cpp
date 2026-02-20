#include "vtremoted-client.h"
#include "vtremoted-protocol.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

struct Args {
  std::string host = "127.0.0.1";
  int port = VTR_PORT;
  std::string token;
};

bool parse_args(int argc, char **argv, Args &args) {
  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--host") == 0 && i + 1 < argc) {
      args.host = argv[++i];
    } else if (std::strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
      args.port = std::atoi(argv[++i]);
    } else if (std::strcmp(argv[i], "--token") == 0 && i + 1 < argc) {
      args.token = argv[++i];
    } else {
      std::fprintf(stderr, "unknown arg: %s\n", argv[i]);
      return false;
    }
  }
  return args.port > 0;
}

} // namespace

int main(int argc, char **argv) {
  Args args;
  if (!parse_args(argc, argv, args)) {
    std::fprintf(stderr, "usage: %s [--host HOST] [--port PORT] [--token TOKEN]\n", argv[0]);
    return 2;
  }

  VTRemotedClient *client = vtremoted_client_create();
  if (!client) {
    std::fprintf(stderr, "failed to create client\n");
    return 1;
  }

  const bool connected =
      vtremoted_client_connect(client, args.host.c_str(), args.port, args.token.c_str());
  if (!connected) {
    std::fprintf(stderr, "connect failed\n");
    vtremoted_client_destroy(client);
    return 1;
  }

  const bool configured = vtremoted_client_configure(
      client,
      64,
      64,
      static_cast<uint8_t>(VTR_PIX_FMT_NV12),
      1,
      30,
      30,
      1,
      1'000'000,
      60,
      VTR_WIRE_NONE);

  if (!configured) {
    std::fprintf(stderr, "configure failed\n");
    vtremoted_client_destroy(client);
    return 1;
  }

  size_t extradata_size = 0;
  const uint8_t *extradata = vtremoted_client_get_extradata(client, &extradata_size);
  if (extradata_size != 0 || extradata != nullptr) {
    std::fprintf(stderr, "expected empty extradata, got size=%zu\n", extradata_size);
    vtremoted_client_destroy(client);
    return 1;
  }

  std::vector<uint8_t> y_plane(64 * 64, 0x10);
  std::vector<uint8_t> uv_plane(64 * 32, 0x80);

  const uint8_t *planes[2] = {y_plane.data(), uv_plane.data()};
  const uint32_t strides[2] = {64, 64};
  const uint32_t heights[2] = {64, 32};
  const uint32_t sizes[2] = {
      static_cast<uint32_t>(y_plane.size()),
      static_cast<uint32_t>(uv_plane.size()),
  };

  const bool sent = vtremoted_client_send_frame(
      client,
      123,
      1,
      2,
      planes,
      strides,
      heights,
      sizes);

  if (!sent) {
    std::fprintf(stderr, "send_frame failed\n");
    vtremoted_client_destroy(client);
    return 1;
  }

  const uint8_t *packet_data = nullptr;
  size_t packet_size = 0;
  int64_t pts = 0;
  int64_t dts = 0;
  bool keyframe = true;

  const bool received = vtremoted_client_receive_packet(
      client,
      &packet_data,
      &packet_size,
      &pts,
      &dts,
      &keyframe);

  if (!received) {
    std::fprintf(stderr, "receive_packet failed\n");
    vtremoted_client_destroy(client);
    return 1;
  }

  if (packet_data == nullptr || packet_size == 0) {
    std::fprintf(stderr, "packet payload missing\n");
    vtremoted_client_destroy(client);
    return 1;
  }

  if (pts != 123 || dts != 123) {
    std::fprintf(stderr, "unexpected pts/dts: %lld/%lld\n",
                 static_cast<long long>(pts),
                 static_cast<long long>(dts));
    vtremoted_client_destroy(client);
    return 1;
  }

  if (keyframe) {
    std::fprintf(stderr, "unexpected keyframe flag\n");
    vtremoted_client_destroy(client);
    return 1;
  }

  vtremoted_client_destroy(client);
  std::printf("OK: obs plugin client smoke test passed\n");
  return 0;
}
