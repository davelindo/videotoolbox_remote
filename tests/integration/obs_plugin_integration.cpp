#include <obs.h>

#include <dlfcn.h>

#include <array>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include "vtremoted-protocol.h"

namespace {

struct Args {
  std::string module_path;
  std::string module_data_path;
  std::string host = "127.0.0.1";
  std::string token;
  std::string expected_extradata_hex;
  int port = VTR_PORT;
  int bitrate = 6000;
  int updated_bitrate = 7000;
  int keyint_sec = 2;
  int updated_keyint_sec = 3;
  int wire_compression = VTR_WIRE_LZ4;
};

[[noreturn]] void fail(const std::string &message) {
  throw std::runtime_error(message);
}

void require(bool condition, const std::string &message) {
  if (!condition)
    fail(message);
}

int parse_wire_compression(const std::string &value) {
  if (value == "none")
    return VTR_WIRE_NONE;
  if (value == "lz4")
    return VTR_WIRE_LZ4;
  if (value == "zstd")
    return VTR_WIRE_ZSTD;
  fail("unsupported --wire-compression value: " + value);
  return VTR_WIRE_NONE;
}

uint8_t parse_hex_nibble(char c) {
  if (c >= '0' && c <= '9')
    return static_cast<uint8_t>(c - '0');
  if (c >= 'a' && c <= 'f')
    return static_cast<uint8_t>(10 + (c - 'a'));
  if (c >= 'A' && c <= 'F')
    return static_cast<uint8_t>(10 + (c - 'A'));
  fail("invalid hex digit");
  return 0;
}

std::vector<uint8_t> decode_hex(const std::string &hex) {
  if (hex.empty())
    return {};
  require((hex.size() % 2) == 0, "hex strings must have even length");

  std::vector<uint8_t> bytes;
  bytes.reserve(hex.size() / 2);
  for (size_t i = 0; i < hex.size(); i += 2) {
    uint8_t hi = parse_hex_nibble(hex[i]);
    uint8_t lo = parse_hex_nibble(hex[i + 1]);
    bytes.push_back(static_cast<uint8_t>((hi << 4) | lo));
  }
  return bytes;
}

Args parse_args(int argc, char **argv) {
  Args args;

  for (int i = 1; i < argc; ++i) {
    std::string arg = argv[i];
    auto require_value = [&](const char *name) -> std::string {
      if (i + 1 >= argc)
        fail(std::string("missing value for ") + name);
      return argv[++i];
    };

    if (arg == "--module-path") {
      args.module_path = require_value("--module-path");
    } else if (arg == "--module-data-path") {
      args.module_data_path = require_value("--module-data-path");
    } else if (arg == "--host") {
      args.host = require_value("--host");
    } else if (arg == "--port") {
      args.port = std::stoi(require_value("--port"));
    } else if (arg == "--token") {
      args.token = require_value("--token");
    } else if (arg == "--wire-compression") {
      args.wire_compression = parse_wire_compression(require_value("--wire-compression"));
    } else if (arg == "--bitrate") {
      args.bitrate = std::stoi(require_value("--bitrate"));
    } else if (arg == "--updated-bitrate") {
      args.updated_bitrate = std::stoi(require_value("--updated-bitrate"));
    } else if (arg == "--keyint-sec") {
      args.keyint_sec = std::stoi(require_value("--keyint-sec"));
    } else if (arg == "--updated-keyint-sec") {
      args.updated_keyint_sec = std::stoi(require_value("--updated-keyint-sec"));
    } else if (arg == "--expected-extradata-hex") {
      args.expected_extradata_hex = require_value("--expected-extradata-hex");
    } else {
      fail("unknown argument: " + arg);
    }
  }

  require(!args.module_path.empty(), "--module-path is required");
  require(!args.module_data_path.empty(), "--module-data-path is required");
  require(args.port > 0 && args.port <= 65535, "--port out of range");
  require(args.bitrate > 0, "--bitrate must be positive");
  require(args.updated_bitrate > 0, "--updated-bitrate must be positive");
  require(args.keyint_sec >= 0, "--keyint-sec must be non-negative");
  require(args.updated_keyint_sec >= 0, "--updated-keyint-sec must be non-negative");

  return args;
}

struct ObsContextGuard {
  ObsContextGuard() {
    require(obs_startup("en-US", nullptr, nullptr), "obs_startup failed");
  }
  ~ObsContextGuard() { obs_shutdown(); }
};

struct ObsDataHandle {
  obs_data_t *ptr = nullptr;
  ~ObsDataHandle() {
    if (ptr)
      obs_data_release(ptr);
  }
};

struct ObsPropertiesHandle {
  obs_properties_t *ptr = nullptr;
  ~ObsPropertiesHandle() {
    if (ptr)
      obs_properties_destroy(ptr);
  }
};

struct ObsEncoderHandle {
  obs_encoder_t *ptr = nullptr;
  void reset() {
    if (ptr) {
      obs_encoder_release(ptr);
      ptr = nullptr;
    }
  }
  ~ObsEncoderHandle() {
    reset();
  }
};

struct VideoHandle {
  video_t *ptr = nullptr;
  void reset() {
    if (ptr) {
      video_output_close(ptr);
      ptr = nullptr;
    }
  }
  ~VideoHandle() {
    reset();
  }
};

struct ModuleHandle {
  obs_module_t *ptr = nullptr;
};

struct EncoderDataHandle {
  const struct obs_encoder_info *info = nullptr;
  void *ptr = nullptr;
  void reset() {
    if (info && ptr) {
      info->destroy(ptr);
      ptr = nullptr;
    }
  }
  ~EncoderDataHandle() {
    reset();
  }
};

void fill_encoder_settings(obs_data_t *settings, const Args &args, int bitrate,
                           int keyint_sec) {
  obs_data_set_string(settings, "host", args.host.c_str());
  obs_data_set_int(settings, "port", args.port);
  obs_data_set_string(settings, "token", args.token.c_str());
  obs_data_set_string(settings, "codec", "h264");
  obs_data_set_int(settings, "bitrate", bitrate);
  obs_data_set_int(settings, "keyint_sec", keyint_sec);
  obs_data_set_int(settings, "wire_compression", args.wire_compression);
}

void validate_defaults() {
  ObsDataHandle defaults{obs_encoder_defaults("vtremoted_encoder")};
  require(defaults.ptr != nullptr, "obs_encoder_defaults returned null");
  require(std::string(obs_data_get_string(defaults.ptr, "host")) == "127.0.0.1",
          "unexpected default host");
  require(obs_data_get_int(defaults.ptr, "port") == VTR_PORT,
          "unexpected default port");
  require(obs_data_get_int(defaults.ptr, "bitrate") == 6000,
          "unexpected default bitrate");
  require(obs_data_get_int(defaults.ptr, "keyint_sec") == 2,
          "unexpected default keyint_sec");
  require(obs_data_get_int(defaults.ptr, "wire_compression") == VTR_WIRE_LZ4,
          "unexpected default wire_compression");
  require(std::string(obs_data_get_string(defaults.ptr, "codec")) == "h264",
          "unexpected default codec");
}

void validate_properties() {
  ObsPropertiesHandle props{obs_get_encoder_properties("vtremoted_encoder")};
  require(props.ptr != nullptr, "obs_get_encoder_properties returned null");

  obs_property_t *wire =
      obs_properties_get(props.ptr, "wire_compression");
  require(wire != nullptr, "wire_compression property missing");
  require(obs_property_get_type(wire) == OBS_PROPERTY_LIST,
          "wire_compression property type mismatch");
  require(obs_property_list_format(wire) == OBS_COMBO_FORMAT_INT,
          "wire_compression list format mismatch");
  require(obs_property_list_item_count(wire) == 3,
          "wire_compression item count mismatch");

  struct ExpectedItem {
    const char *name;
    int value;
  };
  constexpr std::array<ExpectedItem, 3> expected = {{
      {"None", VTR_WIRE_NONE},
      {"LZ4", VTR_WIRE_LZ4},
      {"Zstd", VTR_WIRE_ZSTD},
  }};

  for (size_t i = 0; i < expected.size(); ++i) {
    require(std::string(obs_property_list_item_name(wire, i)) == expected[i].name,
            "wire_compression item name mismatch");
    require(obs_property_list_item_int(wire, i) == expected[i].value,
            "wire_compression item value mismatch");
  }

  obs_property_t *codec =
      obs_properties_get(props.ptr, "codec");
  require(codec != nullptr, "codec property missing");
  require(obs_property_get_type(codec) == OBS_PROPERTY_LIST,
          "codec property type mismatch");
  require(obs_property_list_format(codec) == OBS_COMBO_FORMAT_STRING,
          "codec list format mismatch");
  require(obs_property_list_item_count(codec) == 2,
          "codec item count mismatch");
  require(std::string(obs_property_list_item_name(codec, 0)) == "H.264 (AVC)",
          "codec item 0 name mismatch");
  require(std::string(obs_property_list_item_string(codec, 0)) == "h264",
          "codec item 0 value mismatch");
  require(std::string(obs_property_list_item_name(codec, 1)) == "HEVC (H.265)",
          "codec item 1 name mismatch");
  require(std::string(obs_property_list_item_string(codec, 1)) == "hevc",
          "codec item 1 value mismatch");
}

const struct obs_encoder_info *load_encoder_info(obs_module_t *module) {
  void *lib = obs_get_module_lib(module);
  require(lib != nullptr, "obs_get_module_lib returned null");

  dlerror();
  const auto *info = reinterpret_cast<const struct obs_encoder_info *>(
      dlsym(lib, "vtremoted_encoder_info"));
  const char *err = dlerror();
  require(err == nullptr && info != nullptr,
          std::string("failed to resolve vtremoted_encoder_info: ") +
              (err ? err : "unknown error"));
  return info;
}

VideoHandle create_video_output(uint32_t width, uint32_t height) {
  VideoHandle video;
  struct video_output_info info = {};
  info.name = "vtremoted-integration-video";
  info.format = VIDEO_FORMAT_NV12;
  info.fps_num = 30;
  info.fps_den = 1;
  info.width = width;
  info.height = height;
  info.cache_size = 6;
  info.colorspace = VIDEO_CS_709;
  info.range = VIDEO_RANGE_PARTIAL;

  int rc = video_output_open(&video.ptr, &info);
  require(rc == VIDEO_OUTPUT_SUCCESS, "video_output_open failed");
  return video;
}

std::vector<uint8_t> make_plane(size_t size, uint8_t seed) {
  std::vector<uint8_t> data(size);
  for (size_t i = 0; i < size; ++i)
    data[i] = static_cast<uint8_t>(seed + (i % 17));
  return data;
}

void validate_packet(const struct encoder_packet &packet, int64_t pts) {
  static constexpr uint8_t expected_prefix[] = {0x00, 0x00, 0x00,
                                                0x01, 0x65, 0x88};
  require(packet.type == OBS_ENCODER_VIDEO, "packet type mismatch");
  require(packet.data != nullptr, "packet data missing");
  require(packet.size >= sizeof(expected_prefix), "packet size too small");
  require(packet.pts == pts, "packet pts mismatch");
  require(packet.dts == pts, "packet dts mismatch");
  require(std::memcmp(packet.data, expected_prefix, sizeof(expected_prefix)) == 0,
          "packet Annex B prefix mismatch");
}

void validate_extradata(const struct obs_encoder_info *info, void *data,
                        const std::vector<uint8_t> &expected) {
  uint8_t *extra = nullptr;
  size_t size = 0;
  bool ok = info->get_extra_data(data, &extra, &size);

  if (expected.empty()) {
    require(!ok, "unexpected extradata");
    require(extra == nullptr, "unexpected extradata pointer");
    require(size == 0, "unexpected extradata size");
    return;
  }

  require(ok, "expected extradata");
  require(size == expected.size(), "extradata size mismatch");
  require(std::memcmp(extra, expected.data(), expected.size()) == 0,
          "extradata contents mismatch");
}

int run(const Args &args) {
  static constexpr uint32_t kWidth = 320;
  static constexpr uint32_t kHeight = 180;

  ObsContextGuard obs;

  ModuleHandle module;
  int open_rc = obs_open_module(&module.ptr, args.module_path.c_str(),
                                args.module_data_path.c_str());
  require(open_rc == MODULE_SUCCESS, "obs_open_module failed");
  require(obs_init_module(module.ptr), "obs_init_module failed");
  obs_post_load_modules();

  const char *codec = obs_get_encoder_codec("vtremoted_encoder");
  require(codec != nullptr, "obs_get_encoder_codec returned null");
  require(std::string(codec) == "h264",
          "encoder codec mismatch");
  const char *display_name = obs_encoder_get_display_name("vtremoted_encoder");
  require(display_name != nullptr,
          "obs_encoder_get_display_name returned null");
  require(std::string(display_name) ==
              "VideoToolbox Remote",
          "encoder display name mismatch");

  validate_defaults();
  validate_properties();

  ObsDataHandle settings{obs_data_create()};
  require(settings.ptr != nullptr, "obs_data_create failed");
  fill_encoder_settings(settings.ptr, args, args.bitrate, args.keyint_sec);

  ObsEncoderHandle encoder{obs_video_encoder_create(
      "vtremoted_encoder", "vtremoted-integration", settings.ptr, nullptr)};
  require(encoder.ptr != nullptr, "obs_video_encoder_create failed");

  VideoHandle video = create_video_output(kWidth, kHeight);
  obs_encoder_set_scaled_size(encoder.ptr, kWidth, kHeight);
  obs_encoder_set_video(encoder.ptr, video.ptr);

  require(obs_encoder_video(encoder.ptr) == video.ptr,
          "obs_encoder_set_video did not stick");
  require(obs_encoder_get_width(encoder.ptr) == kWidth,
          "encoder width mismatch");
  require(obs_encoder_get_height(encoder.ptr) == kHeight,
          "encoder height mismatch");
  require(std::string(obs_encoder_get_name(encoder.ptr)) ==
              "vtremoted-integration",
          "encoder name mismatch");

  const struct obs_encoder_info *info = load_encoder_info(module.ptr);
  require(info->create != nullptr, "encoder create callback missing");
  require(info->encode != nullptr, "encoder encode callback missing");
  require(info->destroy != nullptr, "encoder destroy callback missing");
  require(info->get_video_info != nullptr, "encoder get_video_info missing");
  require(info->get_extra_data != nullptr, "encoder get_extra_data missing");

  EncoderDataHandle data{info, info->create(settings.ptr, encoder.ptr)};
  require(data.ptr != nullptr, "encoder create callback failed");

  if (args.updated_bitrate != args.bitrate ||
      args.updated_keyint_sec != args.keyint_sec) {
    require(info->update != nullptr, "encoder update callback missing");
    ObsDataHandle updated{obs_data_create()};
    require(updated.ptr != nullptr, "updated obs_data_create failed");
    fill_encoder_settings(updated.ptr, args, args.updated_bitrate,
                          args.updated_keyint_sec);
    require(info->update(data.ptr, updated.ptr), "encoder update callback failed");
  }

  struct video_scale_info video_info = {};
  info->get_video_info(data.ptr, &video_info);
  require(video_info.format == VIDEO_FORMAT_NV12,
          "encoder requested unexpected video format");

  const std::vector<uint8_t> expected_extradata =
      decode_hex(args.expected_extradata_hex);

  std::vector<uint8_t> y_plane = make_plane(kWidth * kHeight, 0x10);
  std::vector<uint8_t> uv_plane = make_plane(kWidth * (kHeight / 2), 0x80);

  struct encoder_frame frame = {};
  frame.data[0] = y_plane.data();
  frame.data[1] = uv_plane.data();
  frame.linesize[0] = kWidth;
  frame.linesize[1] = kWidth;

  for (int i = 0; i < 2; ++i) {
    frame.pts = 1000 + (i * 1000);
    struct encoder_packet packet = {};
    bool received_packet = false;

    require(info->encode(data.ptr, &frame, &packet, &received_packet),
            "encoder encode callback failed");
    require(received_packet, "encoder did not return a packet");
    validate_packet(packet, frame.pts);

    if (i == 0)
      validate_extradata(info, data.ptr, expected_extradata);
  }

  data.reset();
  encoder.reset();
  video.reset();
  return 0;
}

} // namespace

int main(int argc, char **argv) {
  try {
    return run(parse_args(argc, argv));
  } catch (const std::exception &ex) {
    std::cerr << "ERROR: " << ex.what() << '\n';
    return 1;
  }
}
