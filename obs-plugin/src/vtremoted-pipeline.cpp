#include "vtremoted-pipeline.h"
#include <algorithm>
#include <array>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

struct QueuedFrame {
  int64_t pts;
  std::array<std::vector<uint8_t>, 2> planes;
  std::array<uint32_t, 2> strides, heights, sizes;
};
struct QueuedPacket {
  std::vector<uint8_t> bytes;
  int64_t pts, dts;
  bool keyframe;
};

struct VTRemotedPipeline {
  VTRemotedClient *client;
  size_t capacity, frame_bytes, outstanding = 0;
  std::mutex mutex;
  std::condition_variable changed;
  std::deque<QueuedFrame> frames;
  std::deque<QueuedPacket> packets;
  std::deque<int64_t> awaiting;
  QueuedPacket returned;
  std::thread sender, receiver;
  bool stopped = false, flushing = false, flush_sent = false, done = false;
  std::string error;

  void fail(const char *message) {
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (error.empty())
        error = message;
      stopped = true;
    }
    vtremoted_client_cancel(client);
    changed.notify_all();
  }
  void network_failed() {
    char detail[1024] = {0};
    vtremoted_client_get_error(client, detail, sizeof(detail));
    fail(detail[0] ? detail : "Remote encoder transport failed.");
  }
  void send_loop() {
    for (;;) {
      QueuedFrame frame;
      bool flush;
      {
        std::unique_lock<std::mutex> lock(mutex);
        changed.wait(lock, [&] { return stopped || !frames.empty() || flushing; });
        if (stopped)
          return;
        flush = frames.empty();
        if (flush) {
          flush_sent = true;
        } else {
          frame = std::move(frames.front());
          frames.pop_front();
          awaiting.push_back(frame.pts);
        }
      }
      changed.notify_all();
      if (flush) {
        if (!vtremoted_client_flush(client))
          network_failed();
        return;
      }
      const uint8_t *planes[2] = {frame.planes[0].data(), frame.planes[1].data()};
      if (!vtremoted_client_send_frame(client, frame.pts, 1, 2, planes, frame.strides.data(),
                                       frame.heights.data(), frame.sizes.data())) {
        network_failed();
        return;
      }
    }
  }
  void receive_loop() {
    for (;;) {
      {
        std::unique_lock<std::mutex> lock(mutex);
        changed.wait(lock, [&] { return stopped || !awaiting.empty() || flush_sent; });
        if (stopped)
          return;
      }
      QueuedPacket packet;
      const uint8_t *bytes = nullptr;
      size_t size = 0;
      VTRReceiveResult result = vtremoted_client_receive_packet(
          client, &bytes, &size, &packet.pts, &packet.dts, &packet.keyframe, 5000);
      if (result == VTR_RECEIVE_PENDING)
        continue;
      if (result == VTR_RECEIVE_ERROR) {
        network_failed();
        return;
      }
      std::unique_lock<std::mutex> lock(mutex);
      if (result == VTR_RECEIVE_DONE) {
        if (!flush_sent || !awaiting.empty()) {
          lock.unlock();
          fail("Remote encoder ended before all submitted frames completed.");
        } else {
          done = true;
        }
        return;
      }
      if (awaiting.empty() || awaiting.front() != packet.pts) {
        lock.unlock();
        fail("Remote packet does not match the submitted frame.");
        return;
      }
      awaiting.pop_front();
      packet.bytes.assign(bytes, bytes + size);
      packets.push_back(std::move(packet));
    }
  }
};

VTRemotedPipeline *vtremoted_pipeline_create(VTRemotedClient *client, size_t frame_bytes) {
  constexpr size_t memory_budget = 128 * 1024 * 1024;
  if (!client || !frame_bytes || frame_bytes > memory_budget)
    return nullptr;
  auto *pipeline = new VTRemotedPipeline;
  pipeline->client = client;
  pipeline->frame_bytes = frame_bytes;
  /* Eight frames = 133 ms at 60 fps; large frames also obey the byte budget. */
  pipeline->capacity = std::min<size_t>(8, memory_budget / frame_bytes);
  try {
    pipeline->sender = std::thread([pipeline] { pipeline->send_loop(); });
    pipeline->receiver = std::thread([pipeline] { pipeline->receive_loop(); });
  } catch (...) {
    vtremoted_pipeline_destroy(pipeline);
    return nullptr;
  }
  return pipeline;
}

void vtremoted_pipeline_destroy(VTRemotedPipeline *pipeline) {
  if (!pipeline)
    return;
  {
    std::lock_guard<std::mutex> lock(pipeline->mutex);
    pipeline->stopped = true;
  }
  vtremoted_client_cancel(pipeline->client);
  pipeline->changed.notify_all();
  if (pipeline->sender.joinable())
    pipeline->sender.join();
  if (pipeline->receiver.joinable())
    pipeline->receiver.join();
  delete pipeline;
}

bool vtremoted_pipeline_submit(VTRemotedPipeline *pipeline, int64_t pts,
                               const uint8_t *const planes[2], const uint32_t strides[2],
                               const uint32_t heights[2], const uint32_t sizes[2]) {
  if (!pipeline)
    return false;
  std::unique_lock<std::mutex> lock(pipeline->mutex);
  if (pipeline->stopped || pipeline->flushing)
    return false;
  if (pipeline->outstanding >= pipeline->capacity ||
      (size_t)sizes[0] + sizes[1] > pipeline->frame_bytes) {
    lock.unlock();
    pipeline->fail("Remote encoder queue is full; the server cannot keep up with this video rate.");
    return false;
  }
  QueuedFrame frame;
  frame.pts = pts;
  for (int plane = 0; plane < 2; ++plane) {
    if (!planes[plane] || !sizes[plane])
      return false;
    frame.planes[plane].assign(planes[plane], planes[plane] + sizes[plane]);
    frame.strides[plane] = strides[plane];
    frame.heights[plane] = heights[plane];
    frame.sizes[plane] = sizes[plane];
  }
  ++pipeline->outstanding;
  pipeline->frames.push_back(std::move(frame));
  pipeline->changed.notify_all();
  return true;
}

void vtremoted_pipeline_flush(VTRemotedPipeline *pipeline) {
  if (!pipeline)
    return;
  std::lock_guard<std::mutex> lock(pipeline->mutex);
  pipeline->flushing = true;
  pipeline->changed.notify_all();
}

VTRReceiveResult vtremoted_pipeline_receive(VTRemotedPipeline *pipeline, const uint8_t **data,
                                            size_t *size, int64_t *pts, int64_t *dts,
                                            bool *keyframe) {
  if (!pipeline)
    return VTR_RECEIVE_ERROR;
  std::lock_guard<std::mutex> lock(pipeline->mutex);
  if (!pipeline->error.empty())
    return VTR_RECEIVE_ERROR;
  if (pipeline->packets.empty())
    return pipeline->done ? VTR_RECEIVE_DONE : VTR_RECEIVE_PENDING;
  pipeline->returned = std::move(pipeline->packets.front());
  pipeline->packets.pop_front();
  --pipeline->outstanding;
  *data = pipeline->returned.bytes.data();
  *size = pipeline->returned.bytes.size();
  *pts = pipeline->returned.pts;
  *dts = pipeline->returned.dts;
  *keyframe = pipeline->returned.keyframe;
  return VTR_RECEIVE_PACKET;
}

void vtremoted_pipeline_get_error(VTRemotedPipeline *pipeline, char *error, size_t size) {
  if (!pipeline || !error || !size)
    return;
  std::lock_guard<std::mutex> lock(pipeline->mutex);
  std::snprintf(error, size, "%s", pipeline->error.c_str());
}
