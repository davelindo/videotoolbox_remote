/* Local libobs recording through its normal output start/stop lifecycle. */
#include <obs.h>
#include <obs-avc.h>
#include <obs-hevc.h>
#include <media-io/video-frame.h>
#include <util/platform.h>
#include <dlfcn.h>
#include <atomic>
#include <chrono>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
extern "C" {
#include <libavformat/avformat.h>
}

static const obs_encoder_info *encoder_info;
static std::atomic<int> submitted{0};

static bool observe_encode(void *data, encoder_frame *frame, encoder_packet *packet,
                           bool *received) {
  bool ok = encoder_info->encode(data, frame, packet, received);
  if (frame && ok)
    ++submitted;
  return ok;
}

struct Recording {
  obs_output_t *output = nullptr;
  AVFormatContext *format = nullptr;
  AVStream *stream = nullptr;
  std::string path, codec;
  std::atomic<int> packets{0};
  std::atomic<bool> failed{false};
  size_t extradata_size = 0;
  bool header_written = false;
  ~Recording() {
    if (format) {
      if (header_written && av_write_trailer(format) < 0)
        failed = true;
      avio_closep(&format->pb);
      avformat_free_context(format);
    }
  }
};
static Recording *recording;

static bool start_recording(void *data) {
  auto *r = static_cast<Recording *>(data);
  if (!obs_output_initialize_encoders(r->output, 0))
    return false;
  auto *encoder = obs_output_get_video_encoder(r->output);
  r->codec = obs_encoder_get_codec(encoder);
  uint8_t *extra = nullptr;
  if (!obs_encoder_get_extra_data(encoder, &extra, &r->extradata_size) || !r->extradata_size)
    return false;
  if (avformat_alloc_output_context2(&r->format, nullptr, "matroska", r->path.c_str()) < 0)
    return false;
  r->stream = avformat_new_stream(r->format, nullptr);
  if (!r->stream)
    return false;
  r->stream->time_base = AVRational{1, 30};
  auto *parameters = r->stream->codecpar;
  parameters->codec_type = AVMEDIA_TYPE_VIDEO;
  parameters->codec_id = r->codec == "hevc" ? AV_CODEC_ID_HEVC : AV_CODEC_ID_H264;
  parameters->width = 320;
  parameters->height = 180;
  parameters->extradata =
      static_cast<uint8_t *>(av_mallocz(r->extradata_size + AV_INPUT_BUFFER_PADDING_SIZE));
  if (!parameters->extradata)
    return false;
  parameters->extradata_size = static_cast<int>(r->extradata_size);
  std::memcpy(parameters->extradata, extra, r->extradata_size);
  if (avio_open(&r->format->pb, r->path.c_str(), AVIO_FLAG_WRITE) < 0 ||
      avformat_write_header(r->format, nullptr) < 0)
    return false;
  r->header_written = true;
  return obs_output_begin_data_capture(r->output, 0);
}

static void write_packet(void *data, encoder_packet *source) {
  auto *r = static_cast<Recording *>(data);
  if (!source) {
    r->failed = true;
    return;
  }
  encoder_packet parsed = {};
  if (r->codec == "hevc")
    obs_parse_hevc_packet(&parsed, source);
  else
    obs_parse_avc_packet(&parsed, source);
  AVPacket *packet = av_packet_alloc();
  if (!packet) {
    r->failed = true;
    obs_encoder_packet_release(&parsed);
    return;
  }
  packet->data = parsed.data;
  packet->size = static_cast<int>(parsed.size);
  packet->pts = parsed.pts;
  packet->dts = parsed.dts;
  packet->duration = 1;
  packet->flags = parsed.keyframe ? AV_PKT_FLAG_KEY : 0;
  packet->stream_index = r->stream->index;
  av_packet_rescale_ts(packet, AVRational{1, 30}, r->stream->time_base);
  if (av_write_frame(r->format, packet) < 0)
    r->failed = true;
  else
    ++r->packets;
  av_packet_free(&packet);
  obs_encoder_packet_release(&parsed);
}

static void require(bool ok, const char *message) {
  if (!ok)
    throw std::runtime_error(message);
}

int main(int argc, char **argv) {
  if (argc != 7) {
    std::cerr << "usage: obs_recording MODULE DATA PORT h264|hevc OUTPUT FRAMES\n";
    return 2;
  }
  const std::string codec = argv[4];
  const int frames = std::stoi(argv[6]);
  const bool hevc = codec == "hevc";
  obs_output_t *output = nullptr;
  obs_encoder_t *encoder = nullptr;
  video_t *video = nullptr;
  int result = 1;
  if (!obs_startup("en-US", nullptr, nullptr))
    return 1;
  try {
    require((codec == "h264" || hevc) && frames > 0, "invalid recording arguments");
    obs_module_t *module = nullptr;
    require(obs_open_module(&module, argv[1], argv[2]) == MODULE_SUCCESS && obs_init_module(module),
            "could not load plugin");
    obs_post_load_modules();
    encoder_info = static_cast<const obs_encoder_info *>(
        dlsym(obs_get_module_lib(module),
              hevc ? "vtremoted_hevc_encoder_info" : "vtremoted_encoder_info"));
    require(encoder_info && codec == encoder_info->codec, "OBS codec registration mismatch");
    obs_encoder_info observed = *encoder_info;
    observed.id = "vtremote_recording_test";
    observed.encode = observe_encode;
    obs_register_encoder(&observed);

    obs_output_info info = {};
    info.id = "vtremote_local_recording_test";
    info.flags = OBS_OUTPUT_VIDEO | OBS_OUTPUT_ENCODED;
    info.get_name = [](void *) { return "Local recording test"; };
    info.create = [](obs_data_t *settings, obs_output_t *output) -> void * {
      recording = new Recording;
      recording->output = output;
      recording->path = obs_data_get_string(settings, "path");
      return recording;
    };
    info.destroy = [](void *data) { delete static_cast<Recording *>(data); };
    info.start = start_recording;
    info.stop = [](void *data, uint64_t) {
      obs_output_end_data_capture(static_cast<Recording *>(data)->output);
    };
    info.encoded_packet = write_packet;
    info.encoded_video_codecs = "h264;hevc";
    obs_register_output(&info);

    video_output_info vi = {};
    vi.name = "disposable recording frames";
    vi.format = hevc ? VIDEO_FORMAT_P010 : VIDEO_FORMAT_NV12;
    vi.fps_num = 30;
    vi.fps_den = 1;
    vi.width = 320;
    vi.height = 180;
    vi.cache_size = 6;
    vi.colorspace = VIDEO_CS_709;
    vi.range = VIDEO_RANGE_PARTIAL;
    require(video_output_open(&video, &vi) == VIDEO_OUTPUT_SUCCESS, "video output failed");
    obs_data_t *settings = obs_data_create();
    obs_data_set_string(settings, "host", "127.0.0.1");
    obs_data_set_int(settings, "port", std::stoi(argv[3]));
    obs_data_set_int(settings, "bitrate", 2000);
    obs_data_set_int(settings, "keyint_sec", 1);
    obs_data_set_int(settings, "wire_compression", 0);
    obs_data_set_string(settings, "path", argv[5]);
    encoder = obs_video_encoder_create(observed.id, "local test encoder", settings, nullptr);
    require(encoder != nullptr, "encoder allocation failed");
    obs_encoder_set_video(encoder, video);
    output = obs_output_create(info.id, "local test recording", settings, nullptr);
    obs_data_release(settings);
    require(output != nullptr, "recording allocation failed");
    obs_output_set_video_encoder(output, encoder);
    require(obs_output_start(output), "recording start failed");
    const uint64_t started = os_gettime_ns();
    for (int i = 0; i < frames; ++i) {
      video_frame frame = {};
      require(video_output_lock_frame(video, &frame, 1, started + uint64_t(i) * 1000000000 / 30),
              "test video queue overflowed");
      for (int plane = 0; plane < 2; ++plane) {
        for (int row = 0; row < (plane ? 90 : 180); ++row) {
          uint8_t *line = frame.data[plane] + row * frame.linesize[plane];
          if (hevc) {
            auto *samples = reinterpret_cast<uint16_t *>(line);
            for (int x = 0; x < 320; ++x)
              samples[x] = uint16_t((plane ? 512 : 64 + i % 64 * 8) << 6);
          } else
            std::memset(line, plane ? 128 : 16 + i % 190, 320);
        }
      }
      video_output_unlock_frame(video);
      std::this_thread::sleep_for(std::chrono::milliseconds(34));
    }
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while ((submitted < frames || recording->packets < frames) && !recording->failed &&
           std::chrono::steady_clock::now() < deadline)
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    obs_output_stop(output);
    while (obs_output_active(output) && std::chrono::steady_clock::now() < deadline)
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    require(!obs_output_active(output), "normal recording stop timed out");
    require(!recording->failed && submitted == frames && recording->packets == frames,
            "normal recording path lost frames or packets");
    std::cout << "PASS normal libobs recording codec=" << recording->codec << " frames=" << frames
              << " extradata=" << recording->extradata_size << '\n';
    result = 0;
  } catch (const std::exception &error) {
    std::cerr << "ERROR: " << error.what() << '\n';
  }
  if (output)
    obs_output_release(output);
  if (encoder)
    obs_encoder_release(encoder);
  if (video)
    video_output_close(video);
  obs_shutdown();
  return result;
}
