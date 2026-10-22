#include "../../obs-plugin/src/vtremoted-client.cpp"

#include <cassert>
#include <fcntl.h>
#include <future>
#include <sys/resource.h>
#include <thread>

using namespace std::chrono_literals;

struct Connection {
  VTRemotedClient client;
  int peer;

  Connection() {
    int sockets[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    client.sock = sockets[0];
    peer = sockets[1];
    client.connected = true;
    assert(configure_socket_io(client.sock));
    assert(configure_socket_io(peer));
    assert(make_socket_nonblocking(client.sock));
    assert(make_socket_nonblocking(peer));
  }

  ~Connection() {
    vtremoted_client_disconnect(&client);
    close(peer);
  }
};

struct Received {
  VTRReceiveResult result;
  int64_t pts = -1, dts = -1;
  bool keyframe = false;
  std::vector<uint8_t> bytes;
};

static Received receive(Connection &connection, int wait_ms) {
  Received received;
  const uint8_t *data = nullptr;
  size_t size = 0;
  received.result = vtremoted_client_receive_packet(
      &connection.client, &data, &size, &received.pts, &received.dts,
      &received.keyframe, wait_ms);
  if (received.result == VTR_RECEIVE_PACKET)
    received.bytes.assign(data, data + size);
  return received;
}

static std::vector<uint8_t> packet(int64_t pts) {
  std::vector<uint8_t> wire(48);
  write_be32(wire.data(), VTR_MAGIC);
  write_be16(wire.data() + 4, VTR_VERSION);
  write_be16(wire.data() + 6, VTR_MSG_PACKET);
  write_be32(wire.data() + 8, 36);
  write_be64(wire.data() + 12, pts);
  write_be64(wire.data() + 20, pts);
  write_be32(wire.data() + 36, 1);
  write_be32(wire.data() + 40, 4);
  write_be32(wire.data() + 44, 0x00000165);
  return wire;
}

static void send_bytes(int peer, const uint8_t *bytes, size_t size) {
  assert(send(peer, bytes, size, 0) == static_cast<ssize_t>(size));
}

static void test_partial_poll() {
  Connection connection;
  auto wire = packet(42);
  assert(receive(connection, 0).result == VTR_RECEIVE_PENDING);
  send_bytes(connection.peer, wire.data(), 5);
  auto started = SocketClock::now();
  assert(receive(connection, 0).result == VTR_RECEIVE_PENDING);
  assert(SocketClock::now() - started < 100ms);
  send_bytes(connection.peer, wire.data() + 5, 9);
  assert(receive(connection, 0).result == VTR_RECEIVE_PENDING);
  send_bytes(connection.peer, wire.data() + 14, wire.size() - 14);
  auto received = receive(connection, 0);
  assert(received.result == VTR_RECEIVE_PACKET);
  assert(received.pts == 42 && received.dts == 42 && received.keyframe);
  assert(received.bytes == std::vector<uint8_t>({0, 0, 1, 0x65}));
  wire = packet(43);
  send_bytes(connection.peer, wire.data(), wire.size());
  assert(receive(connection, 0).pts == 43);
  assert(receive(connection, 0).result == VTR_RECEIVE_PENDING);
}

static void test_receive_deadline(size_t prefix_size) {
  Connection connection;
  auto wire = packet(42);
  send_bytes(connection.peer, wire.data(), prefix_size);
  std::thread peer([&] {
    for (size_t i = prefix_size; i < wire.size(); ++i) {
      std::this_thread::sleep_for(20ms);
      int flags = 0;
#ifdef MSG_NOSIGNAL
      flags = MSG_NOSIGNAL;
#endif
      if (send(connection.peer, wire.data() + i, 1, flags) != 1)
        break;
    }
  });
  auto started = SocketClock::now();
  auto result = receive(connection, 60).result;
  auto elapsed = SocketClock::now() - started;
  peer.join();
  assert(result == VTR_RECEIVE_ERROR && !connection.client.connected);
  assert(elapsed >= 40ms && elapsed < 250ms);
}

static void test_high_descriptor() {
  Connection connection;
  rlimit limit;
  assert(getrlimit(RLIMIT_NOFILE, &limit) == 0);
  if (limit.rlim_cur <= FD_SETSIZE && limit.rlim_max > FD_SETSIZE) {
    limit.rlim_cur = FD_SETSIZE + 1;
    assert(setrlimit(RLIMIT_NOFILE, &limit) == 0);
  }
  int descriptor = fcntl(connection.client.sock, F_DUPFD, FD_SETSIZE);
  assert(descriptor >= FD_SETSIZE);
  close(connection.client.sock);
  connection.client.sock = descriptor;
  auto wire = packet(44);
  std::thread peer([&] {
    std::this_thread::sleep_for(10ms);
    send_bytes(connection.peer, wire.data(), wire.size());
  });
  auto received = receive(connection, 250);
  peer.join();
  assert(received.result == VTR_RECEIVE_PACKET && received.pts == 44);
}

static void test_send_deadline() {
  Connection connection;
  int buffer_size = 4096;
  assert(setsockopt(connection.client.sock, SOL_SOCKET, SO_SNDBUF,
                    &buffer_size, sizeof(buffer_size)) == 0);
  std::atomic<bool> stop{false};
  size_t received = 0;
  std::thread peer([&] {
    uint8_t bytes[1024];
    while (!stop) {
      auto count = recv(connection.peer, bytes, sizeof(bytes), MSG_DONTWAIT);
      if (count > 0)
        received += static_cast<size_t>(count);
      std::this_thread::sleep_for(5ms);
    }
  });
  std::vector<uint8_t> body(1024 * 1024, 0x80);
  auto started = SocketClock::now();
  bool sent = send_msg(connection.client.sock, VTR_MSG_FRAME, body.data(),
                       static_cast<uint32_t>(body.size()), started + 60ms);
  auto elapsed = SocketClock::now() - started;
  stop = true;
  peer.join();
  if (sent || received == 0)
    std::fprintf(stderr, "send deadline: sent=%d received=%zu elapsed_ms=%.1f\n", sent,
                 received, std::chrono::duration<double, std::milli>(elapsed).count());
  assert(!sent && received > 0);
  assert(elapsed >= 40ms && elapsed < 250ms);
}

static std::vector<uint8_t> ping(size_t payload_size = 3) {
  std::vector<uint8_t> wire(12 + payload_size);
  write_be32(wire.data(), VTR_MAGIC);
  write_be16(wire.data() + 4, VTR_VERSION);
  write_be16(wire.data() + 6, VTR_MSG_PING);
  write_be32(wire.data() + 8, static_cast<uint32_t>(payload_size));
  for (size_t i = 0; i < payload_size; ++i)
    wire[12 + i] = static_cast<uint8_t>(i % 251);
  return wire;
}

static void check_pong(Connection &connection, std::vector<uint8_t> expected) {
  write_be16(expected.data() + 6, VTR_MSG_PONG);
  std::vector<uint8_t> received(expected.size());
  assert(read_exact(connection.peer, received.data(), received.size(),
                     SocketClock::now() + 100ms) == READ_OK);
  assert(received == expected);
}

static void test_ping_send_lock(int wait_ms) {
  Connection connection;
  auto wire = ping();
  send_bytes(connection.peer, wire.data(), wire.size());
  std::promise<void> locked, release;
  auto acquired = locked.get_future();
  auto released = release.get_future();
  std::thread sender([&] {
    std::lock_guard<std::timed_mutex> lock(connection.client.send_mutex);
    locked.set_value();
    released.wait();
  });
  acquired.wait();
  auto started = SocketClock::now();
  auto result = receive(connection, wait_ms).result;
  auto elapsed = SocketClock::now() - started;
  release.set_value();
  sender.join();
  if (wait_ms == 0) {
    assert(result == VTR_RECEIVE_PENDING && elapsed < 100ms);
    assert(connection.client.connected);
    assert(receive(connection, 0).result == VTR_RECEIVE_PENDING);
    check_pong(connection, wire);
  } else {
    assert(result == VTR_RECEIVE_ERROR && !connection.client.connected);
    assert(elapsed >= 40ms && elapsed < 250ms);
  }
}

static void test_ping_send_backpressure() {
  Connection connection;
  std::array<uint8_t, 4096> filler{};
  while (send(connection.client.sock, filler.data(), filler.size(), MSG_DONTWAIT) > 0) {}
  assert(errno == EAGAIN || errno == EWOULDBLOCK);
  auto wire = ping();
  send_bytes(connection.peer, wire.data(), wire.size());
  auto started = SocketClock::now();
  assert(receive(connection, 0).result == VTR_RECEIVE_PENDING);
  assert(SocketClock::now() - started < 100ms);
  assert(connection.client.connected);
  while (recv(connection.peer, filler.data(), filler.size(), MSG_DONTWAIT) > 0) {}
  assert(errno == EAGAIN || errno == EWOULDBLOCK);
  assert(receive(connection, 0).result == VTR_RECEIVE_PENDING);
  check_pong(connection, wire);
}

static std::vector<uint8_t> read_wire(int peer) {
  auto deadline = SocketClock::now() + 1s;
  std::vector<uint8_t> wire(12);
  assert(read_exact(peer, wire.data(), wire.size(), deadline) == READ_OK);
  uint32_t size = vtr_read_be32(wire.data() + 8);
  assert(vtr_read_be32(wire.data()) == VTR_MAGIC && size <= 1024 * 1024);
  wire.resize(12 + size);
  assert(read_exact(peer, wire.data() + 12, size, deadline) == READ_OK);
  return wire;
}

static void test_partial_pong(int next_message) {
  Connection connection;
  int buffer_size = 4096;
  assert(setsockopt(connection.client.sock, SOL_SOCKET, SO_SNDBUF,
                    &buffer_size, sizeof(buffer_size)) == 0);
  auto wire = ping(64 * 1024);
  std::thread input([&] {
    assert(write_all(connection.peer, wire.data(), wire.size(), SocketClock::now() + 1s));
  });
  auto deadline = SocketClock::now() + 1s;
  while (connection.client.pong_buf.empty() && SocketClock::now() < deadline) {
    assert(receive(connection, 0).result == VTR_RECEIVE_PENDING);
    std::this_thread::sleep_for(1ms);
  }
  input.join();
  assert(connection.client.connected && connection.client.pong_sent > 0);
  assert(connection.client.pong_sent < connection.client.pong_buf.size());

  std::thread sender;
  if (next_message) {
    connection.client.configured = true;
    connection.client.wire_compression = VTR_WIRE_NONE;
    sender = std::thread([&] {
      if (next_message == VTR_MSG_FLUSH) {
        assert(vtremoted_client_flush(&connection.client));
      } else {
        uint8_t y[4] = {1, 2, 3, 4}, uv[2] = {5, 6};
        const uint8_t *planes[] = {y, uv};
        uint32_t strides[] = {2, 2}, heights[] = {2, 1}, sizes[] = {4, 2};
        assert(vtremoted_client_send_frame(&connection.client, 71, 1, 2, planes,
                                            strides, heights, sizes));
      }
    });
    auto response = read_wire(connection.peer);
    write_be16(wire.data() + 6, VTR_MSG_PONG);
    assert(response == wire);
    response = read_wire(connection.peer);
    assert(vtr_read_be16(response.data() + 6) == next_message);
    if (next_message == VTR_MSG_FRAME)
      assert(vtr_read_be64(response.data() + 12) == 71);
    sender.join();
    assert(receive(connection, 0).result == VTR_RECEIVE_PENDING);
  } else {
    std::vector<uint8_t> response;
    uint8_t bytes[4096];
    deadline = SocketClock::now() + 1s;
    while (response.size() < wire.size() && SocketClock::now() < deadline) {
      auto count = recv(connection.peer, bytes, sizeof(bytes), MSG_DONTWAIT);
      if (count > 0)
        response.insert(response.end(), bytes, bytes + count);
      assert(receive(connection, 0).result == VTR_RECEIVE_PENDING);
    }
    write_be16(wire.data() + 6, VTR_MSG_PONG);
    assert(response == wire);
  }
  assert(connection.client.connected && connection.client.pong_buf.empty());
  uint8_t extra;
  assert(recv(connection.peer, &extra, 1, MSG_DONTWAIT) == -1);
  assert(errno == EAGAIN || errno == EWOULDBLOCK);
}

int main() {
  test_partial_poll();
  test_receive_deadline(1);
  test_receive_deadline(13);
  test_high_descriptor();
  test_send_deadline();
  test_ping_send_lock(0);
  test_ping_send_lock(60);
  test_ping_send_backpressure();
  test_partial_pong(0);
  test_partial_pong(VTR_MSG_FRAME);
  test_partial_pong(VTR_MSG_FLUSH);
  puts("PASS OBS partial polls, deadlines, high descriptors, and ordered resumable PONGs");
}
