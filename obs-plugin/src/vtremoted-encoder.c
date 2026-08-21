/*
 * OBS VideoToolbox Remote Encoder
 * Implements obs_encoder_info for remote encoding via vtremoted
 */

#include <obs-module.h>
#include <util/darray.h>

#include "vtremoted-client.h"
#include "vtremoted-protocol.h"

#define do_log(level, format, ...)                                             \
  blog(level, "[vtremoted encoder: '%s'] " format,                             \
       obs_encoder_get_name(enc->encoder), ##__VA_ARGS__)

#define warn(format, ...) do_log(LOG_WARNING, format, ##__VA_ARGS__)
#define info(format, ...) do_log(LOG_INFO, format, ##__VA_ARGS__)

struct vtremoted_encoder {
  obs_encoder_t *encoder;
  VTRemotedClient *client;

  char *host;
  char *token;
  char *codec;
  int port;
  int bitrate;
  int gop;
  int wire_compression;

  uint8_t *extra_data;
  size_t extra_data_size;

  DARRAY(uint8_t) packet_data;

  bool first_frame;
};

static const char *vtremoted_getname(void *unused) {
  UNUSED_PARAMETER(unused);
  return "VideoToolbox Remote";
}

static void vtremoted_destroy(void *data) {
  struct vtremoted_encoder *enc = data;
  if (!enc)
    return;

  if (enc->client) {
    vtremoted_client_destroy(enc->client);
  }

  bfree(enc->host);
  bfree(enc->token);
  bfree(enc->codec);
  bfree(enc->extra_data);
  da_free(enc->packet_data);
  bfree(enc);
}

static void vtremoted_defaults(obs_data_t *settings) {
  obs_data_set_default_string(settings, "host", "127.0.0.1");
  obs_data_set_default_int(settings, "port", VTR_PORT);
  obs_data_set_default_string(settings, "token", "");
  obs_data_set_default_int(settings, "bitrate", 6000);
  obs_data_set_default_int(settings, "keyint_sec", 2);
  obs_data_set_default_int(settings, "wire_compression", VTR_WIRE_LZ4);
  obs_data_set_default_string(settings, "codec", "h264");
}

static obs_properties_t *vtremoted_properties(void *unused) {
  UNUSED_PARAMETER(unused);

  obs_properties_t *props = obs_properties_create();

  obs_properties_add_text(props, "host", "Server Host", OBS_TEXT_DEFAULT);
  obs_properties_add_int(props, "port", "Server Port", 1, 65535, 1);
  obs_properties_add_text(props, "token", "Auth Token", OBS_TEXT_PASSWORD);

  obs_property_t *codec_list =
      obs_properties_add_list(props, "codec", "Video Codec", OBS_COMBO_TYPE_LIST,
                              OBS_COMBO_FORMAT_STRING);
  obs_property_list_add_string(codec_list, "H.264 (AVC)", "h264");
  obs_property_list_add_string(codec_list, "HEVC (H.265)", "hevc");

  obs_property_t *p =
      obs_properties_add_int(props, "bitrate", "Bitrate", 500, 100000, 100);
  obs_property_int_set_suffix(p, " Kbps");

  p = obs_properties_add_int(props, "keyint_sec", "Keyframe Interval", 0, 20,
                             1);
  obs_property_int_set_suffix(p, " s");

  obs_property_t *list =
      obs_properties_add_list(props, "wire_compression", "Wire Compression",
                              OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_INT);
  obs_property_list_add_int(list, "None", VTR_WIRE_NONE);
  obs_property_list_add_int(list, "LZ4", VTR_WIRE_LZ4);
  obs_property_list_add_int(list, "Zstd", VTR_WIRE_ZSTD);

  return props;
}

static bool vtremoted_is_supported_codec(const char *codec) {
  return codec && (strcmp(codec, "h264") == 0 || strcmp(codec, "hevc") == 0);
}

static void *vtremoted_create(obs_data_t *settings, obs_encoder_t *encoder) {
  struct vtremoted_encoder *enc = bzalloc(sizeof(struct vtremoted_encoder));
  enc->encoder = encoder;
  enc->first_frame = true;

  enc->host = bstrdup(obs_data_get_string(settings, "host"));
  enc->port = (int)obs_data_get_int(settings, "port");
  enc->token = bstrdup(obs_data_get_string(settings, "token"));
  enc->codec = bstrdup(obs_data_get_string(settings, "codec"));
  enc->bitrate = (int)obs_data_get_int(settings, "bitrate");
  enc->gop = (int)obs_data_get_int(settings, "keyint_sec");
  enc->wire_compression = (int)obs_data_get_int(settings, "wire_compression");

  if (!enc->codec || !vtremoted_is_supported_codec(enc->codec)) {
    warn("Unsupported codec requested");
    vtremoted_destroy(enc);
    return NULL;
  }

  enc->client = vtremoted_client_create();
  if (!enc->client) {
    warn("Failed to create client");
    vtremoted_destroy(enc);
    return NULL;
  }

  return enc;
}

static bool vtremoted_update(void *data, obs_data_t *settings) {
  struct vtremoted_encoder *enc = data;

  if (!vtremoted_is_supported_codec(obs_data_get_string(settings, "codec"))) {
    warn("Ignoring unsupported codec change request");
    return false;
  }

  bfree(enc->host);
  bfree(enc->token);
  bfree(enc->codec);

  enc->host = bstrdup(obs_data_get_string(settings, "host"));
  enc->codec = bstrdup(obs_data_get_string(settings, "codec"));
  enc->port = (int)obs_data_get_int(settings, "port");
  enc->token = bstrdup(obs_data_get_string(settings, "token"));
  enc->bitrate = (int)obs_data_get_int(settings, "bitrate");
  enc->gop = (int)obs_data_get_int(settings, "keyint_sec");
  enc->wire_compression = (int)obs_data_get_int(settings, "wire_compression");

  return true;
}

static bool vtremoted_extra_data(void *data, uint8_t **extra_data,
                                 size_t *size) {
  struct vtremoted_encoder *enc = data;
  if (!enc->extra_data || enc->extra_data_size == 0) {
    *extra_data = NULL;
    *size = 0;
    return false;
  }
  *extra_data = enc->extra_data;
  *size = enc->extra_data_size;
  return true;
}

static bool connect_and_configure(struct vtremoted_encoder *enc) {
  video_t *video = obs_encoder_video(enc->encoder);
  if (!video) {
    warn("No video output attached to encoder");
    return false;
  }
  const struct video_output_info *voi = video_output_get_info(video);

  uint32_t width = obs_encoder_get_width(enc->encoder);
  uint32_t height = obs_encoder_get_height(enc->encoder);

  /* Determine pixel format */
  uint32_t pix_fmt = VTR_PIX_FMT_NV12;
  if (voi->format == VIDEO_FORMAT_NV12) {
    pix_fmt = VTR_PIX_FMT_NV12;
  } else if (voi->format == VIDEO_FORMAT_P010) {
    pix_fmt = VTR_PIX_FMT_P010;
  }

  /* Calculate GOP in frames */
  int gop_frames = enc->gop * voi->fps_num / voi->fps_den;
  if (gop_frames <= 0)
    gop_frames = voi->fps_num / voi->fps_den * 2; /* Default 2 sec */

  info("Connecting to %s:%d", enc->host, enc->port);

  if (!vtremoted_client_connect(enc->client, enc->host, enc->port,
                                enc->token, enc->codec)) {
    warn("Failed to connect to server");
    return false;
  }

  info("Configuring %dx%d @ %d kbps, GOP %d", width, height, enc->bitrate,
       gop_frames);

  if (!vtremoted_client_configure(enc->client, width, height, pix_fmt,
                                  voi->fps_den, voi->fps_num, voi->fps_num,
                                  voi->fps_den, enc->bitrate * 1000, gop_frames,
                                  enc->wire_compression)) {
    warn("Failed to configure encoder");
    vtremoted_client_disconnect(enc->client);
    return false;
  }

  /* Get extradata */
  size_t ed_size = 0;
  const uint8_t *ed = vtremoted_client_get_extradata(enc->client, &ed_size);
  if (ed && ed_size > 0) {
    bfree(enc->extra_data);
    enc->extra_data = bmalloc(ed_size);
    memcpy(enc->extra_data, ed, ed_size);
    enc->extra_data_size = ed_size;
  }

  info("Connected and configured successfully");
  return true;
}

static size_t frame_size_nv12(uint32_t width, uint32_t height) {
  return width * height * 3 / 2;
}

static bool vtremoted_encode(void *data, struct encoder_frame *frame,
                             struct encoder_packet *packet,
                             bool *received_packet) {
  struct vtremoted_encoder *enc = data;

  *received_packet = false;

  if (!frame || !packet)
    return false;

  /* Connect on first frame */
  if (enc->first_frame) {
    enc->first_frame = false;
    if (!connect_and_configure(enc)) {
      return false;
    }
  }

  if (!vtremoted_client_is_connected(enc->client)) {
    warn("Not connected");
    return false;
  }

  /* Build semiplanar 4:2:0 frame data (NV12/P010: Y plane + UV plane). */
  uint32_t width = obs_encoder_get_width(enc->encoder);
  uint32_t height = obs_encoder_get_height(enc->encoder);

  /* Plane 0 = Y, plane 1 = UV interleaved. */
  size_t y_size = (size_t)frame->linesize[0] * height;
  size_t uv_size = (size_t)frame->linesize[1] * (height / 2);

  const uint8_t *planes[2] = {frame->data[0], frame->data[1]};
  uint32_t strides[2] = {frame->linesize[0], frame->linesize[1]};
  uint32_t heights_arr[2] = {height, height / 2};
  uint32_t sizes[2] = {(uint32_t)y_size, (uint32_t)uv_size};

  /* Send frame */
  if (!vtremoted_client_send_frame(enc->client, frame->pts, 1, 2, planes,
                                   strides, heights_arr, sizes)) {
    warn("Failed to send frame");
    return false;
  }

  /* Receive packet */
  const uint8_t *pkt_data = NULL;
  size_t pkt_size = 0;
  int64_t pts = 0, dts = 0;
  bool keyframe = false;

  if (!vtremoted_client_receive_packet(enc->client, &pkt_data, &pkt_size, &pts,
                                       &dts, &keyframe)) {
    /* No packet yet (may happen with B-frames buffering) */
    return true;
  }

  /* Fill packet */
  da_resize(enc->packet_data, pkt_size);
  memcpy(enc->packet_data.array, pkt_data, pkt_size);

  packet->data = enc->packet_data.array;
  packet->size = pkt_size;
  packet->type = OBS_ENCODER_VIDEO;
  packet->pts = pts;
  packet->dts = dts;
  packet->keyframe = keyframe;

  *received_packet = true;
  return true;
}

static void vtremoted_video_info(void *data, struct video_scale_info *info) {
  struct vtremoted_encoder *enc = data;

  if (enc) {
    video_t *video = obs_encoder_video(enc->encoder);
    if (video) {
      const struct video_output_info *voi = video_output_get_info(video);
      if (voi && voi->format == VIDEO_FORMAT_P010) {
        info->format = VIDEO_FORMAT_P010;
        return;
      }
    }
  }

  info->format = VIDEO_FORMAT_NV12;
}

struct obs_encoder_info vtremoted_encoder_info = {
    .id = "vtremoted_encoder",
    .type = OBS_ENCODER_VIDEO,
    .codec = "h264",
    .get_name = vtremoted_getname,
    .create = vtremoted_create,
    .destroy = vtremoted_destroy,
    .encode = vtremoted_encode,
    .get_defaults = vtremoted_defaults,
    .get_properties = vtremoted_properties,
    .update = vtremoted_update,
    .get_extra_data = vtremoted_extra_data,
    .get_video_info = vtremoted_video_info,
};
