#include "vtremoted-pipeline.h"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>

int main(int argc, char **argv) {
  if (argc != 4)
    return 2;
  bool synchronous = !std::strcmp(argv[2], "sync");
  int count = std::atoi(argv[3]);
  auto *client = vtremoted_client_create();
  if (!vtremoted_client_connect(client, "127.0.0.1", std::atoi(argv[1]), "", "h264") ||
      !vtremoted_client_configure(client, 64, 64, 1, 1, 60, 60, 1, 1000000, 60, 0))
    return 3;
  auto *pipeline = synchronous ? nullptr : vtremoted_pipeline_create(client, 6144);
  std::vector<uint8_t> y(4096, 16), uv(2048, 128);
  const uint8_t *planes[2] = {y.data(), uv.data()};
  uint32_t strides[2] = {64, 64}, heights[2] = {64, 32}, sizes[2] = {4096, 2048};
  const uint8_t *bytes;
  size_t size;
  int64_t pts, dts;
  bool keyframe;
  int received = 0;
  std::vector<double> callbacks;
  using Clock = std::chrono::steady_clock;
  auto started = Clock::now();
  bool failed = false;
  auto accept = [&](VTRReceiveResult result) {
    if (result == VTR_RECEIVE_PACKET) {
      if (pts != received || dts != received || size == 0)
        failed = true;
      ++received;
    } else if (result == VTR_RECEIVE_ERROR)
      failed = true;
  };
  for (int i = 0; i < count && !failed; ++i) {
    std::this_thread::sleep_until(started + std::chrono::microseconds(i * 1000000 / 60));
    auto before = Clock::now();
    if (synchronous) {
      if (!vtremoted_client_send_frame(client, i, 1, 2, planes, strides, heights, sizes))
        failed = true;
      accept(vtremoted_client_receive_packet(client, &bytes, &size, &pts, &dts, &keyframe, 5000));
    } else {
      if (!vtremoted_pipeline_submit(pipeline, i, planes, strides, heights, sizes))
        failed = true;
      accept(vtremoted_pipeline_receive(pipeline, &bytes, &size, &pts, &dts, &keyframe));
    }
    callbacks.push_back(std::chrono::duration<double, std::milli>(Clock::now() - before).count());
  }
  if (synchronous)
    vtremoted_client_flush(client);
  else
    vtremoted_pipeline_flush(pipeline);
  auto deadline = Clock::now() + std::chrono::seconds(7);
  bool done = false;
  while (!failed && Clock::now() < deadline) {
    VTRReceiveResult result =
        synchronous
            ? vtremoted_client_receive_packet(client, &bytes, &size, &pts, &dts, &keyframe, 5000)
            : vtremoted_pipeline_receive(pipeline, &bytes, &size, &pts, &dts, &keyframe);
    accept(result);
    if (result == VTR_RECEIVE_DONE) {
      done = true;
      break;
    }
    if (result == VTR_RECEIVE_PENDING)
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  double seconds = std::chrono::duration<double>(Clock::now() - started).count();
  std::sort(callbacks.begin(), callbacks.end());
  auto percentile = [&](double q) { return callbacks.at((callbacks.size() - 1) * q); };
  char error[1024] = {0};
  if (pipeline)
    vtremoted_pipeline_get_error(pipeline, error, sizeof(error));
  else
    vtremoted_client_get_error(client, error, sizeof(error));
  if (failed)
    std::fprintf(stderr, "%s\n", error);
  std::printf(
      "{\"mode\":\"%s\",\"frames\":%d,\"seconds\":%.6f,\"fps\":%.3f,"
      "\"callback_p50_ms\":%.4f,\"callback_p95_ms\":%.4f,\"callback_p99_ms\":%.4f,\"done\":%s}\n",
      argv[2], received, seconds, received / seconds, percentile(.5), percentile(.95),
      percentile(.99), done ? "true" : "false");
  vtremoted_pipeline_destroy(pipeline);
  vtremoted_client_destroy(client);
  return failed || !done || received != count;
}
