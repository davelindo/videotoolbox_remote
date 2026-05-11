/*
 * VTRemote protocol header roundtrip tests.
 *
 * This is a minimal sanity check to ensure the fixed header packing/unpacking
 * stays stable and refuses bad inputs (magic/version/size).
 */

#include <string.h>

#include "libavutil/avassert.h"
#include "libavutil/error.h"
#include "libavutil/frame.h"
#include "libavutil/log.h"
#include "libavutil/mem.h"
#include "libavcodec/vtremote_proto.h"

static int test_roundtrip(void)
{
    uint8_t buf[VTREMOTE_HEADER_SIZE];
    VTRemoteMsgHeader in = {
        .magic   = VTREMOTE_PROTO_MAGIC,
        .version = VTREMOTE_PROTO_VERSION,
        .type    = VTREMOTE_MSG_FRAME,
        .length  = 1234,
    };
    VTRemoteMsgHeader out;

    int written = vtremote_write_header(buf, sizeof(buf), &in);
    if (written < 0)
        return written;

    int ret = vtremote_read_header(buf, sizeof(buf), &out);
    if (ret < 0)
        return ret;

    av_assert0(out.magic   == in.magic);
    av_assert0(out.version == in.version);
    av_assert0(out.type    == in.type);
    av_assert0(out.length  == in.length);

    av_assert0(!strcmp(vtremote_msg_type_name(VTREMOTE_MSG_FRAME), "FRAME"));
    av_assert0(!strcmp(vtremote_msg_type_name(0), "UNKNOWN"));

    return 0;
}

static int test_invalid_magic(void)
{
    uint8_t buf[VTREMOTE_HEADER_SIZE];
    VTRemoteMsgHeader bad = {
        .magic   = 0,
        .version = VTREMOTE_PROTO_VERSION,
        .type    = VTREMOTE_MSG_FRAME,
        .length  = 0,
    };
    vtremote_write_header(buf, sizeof(buf), &bad);

    VTRemoteMsgHeader out;
    int ret = vtremote_read_header(buf, sizeof(buf), &out);
    av_assert0(ret == AVERROR_INVALIDDATA);
    return 0;
}

static int test_invalid_version(void)
{
    uint8_t buf[VTREMOTE_HEADER_SIZE];
    VTRemoteMsgHeader bad = {
        .magic   = VTREMOTE_PROTO_MAGIC,
        .version = VTREMOTE_PROTO_VERSION + 1,
        .type    = VTREMOTE_MSG_FRAME,
        .length  = 0,
    };
    vtremote_write_header(buf, sizeof(buf), &bad);

    VTRemoteMsgHeader out;
    int ret = vtremote_read_header(buf, sizeof(buf), &out);
    av_assert0(ret == AVERROR_INVALIDDATA);
    return 0;
}

static int test_short_buffer(void)
{
    uint8_t buf[VTREMOTE_HEADER_SIZE - 1];
    VTRemoteMsgHeader in = {
        .magic   = VTREMOTE_PROTO_MAGIC,
        .version = VTREMOTE_PROTO_VERSION,
        .type    = VTREMOTE_MSG_FRAME,
        .length  = 1,
    };
    int ret = vtremote_write_header(buf, sizeof(buf), &in);
    av_assert0(ret == AVERROR(EINVAL));
    return 0;
}

static int test_build_and_parse_hello(void)
{
    VTRemoteWBuf payload;
    vtremote_wbuf_init(&payload);
    av_assert0(vtremote_payload_hello(&payload, "TOKEN", "h264", "ffmpeg-client", "build123") == 0);

    uint8_t *msg = NULL;
    int msg_size = 0;
    av_assert0(vtremote_build_message(VTREMOTE_MSG_HELLO, &payload, &msg, &msg_size) == 0);
    av_assert0(msg_size == VTREMOTE_HEADER_SIZE + payload.size);

    VTRemoteMsgHeader hdr;
    av_assert0(vtremote_read_header(msg, msg_size, &hdr) == 0);
    av_assert0(hdr.type == VTREMOTE_MSG_HELLO);
    av_assert0(hdr.length == payload.size);

    VTRemoteRBuf r;
    vtremote_rbuf_init(&r, msg + VTREMOTE_HEADER_SIZE, hdr.length);
    const uint8_t *s;
    int len;
    av_assert0(vtremote_rbuf_read_str(&r, &s, &len) == 0);
    av_assert0(len == 5 && !memcmp(s, "TOKEN", 5));
    av_assert0(vtremote_rbuf_read_str(&r, &s, &len) == 0);
    av_assert0(len == 4 && !memcmp(s, "h264", 4));
    av_assert0(vtremote_rbuf_read_str(&r, &s, &len) == 0);
    av_assert0(len == 13 && !memcmp(s, "ffmpeg-client", 13));
    av_assert0(vtremote_rbuf_read_str(&r, &s, &len) == 0);
    av_assert0(len == 8 && !memcmp(s, "build123", 8));
    av_assert0(r.pos == r.size);

    av_free(msg);
    vtremote_wbuf_free(&payload);
    return 0;
}

static int test_build_configure(void)
{
    VTRemoteKV opts[] = {
        {"bitrate", "2000000"},
        {"gop", "60"},
    };
    VTRemoteWBuf b;
    vtremote_wbuf_init(&b);
    av_assert0(vtremote_payload_configure(&b, 1920, 1080, VTREMOTE_PIX_FMT_NV12,
                                          1, 30, 30, 1, opts, 2, NULL, 0) == 0);
    VTRemoteMsgHeader hdr = { VTREMOTE_PROTO_MAGIC, VTREMOTE_PROTO_VERSION, VTREMOTE_MSG_CONFIGURE, (uint32_t)b.size };
    uint8_t header[VTREMOTE_HEADER_SIZE];
    av_assert0(vtremote_write_header(header, sizeof(header), &hdr) == VTREMOTE_HEADER_SIZE);

    VTRemoteRBuf r;
    vtremote_rbuf_init(&r, b.data, b.size);
    uint32_t w,h,tbn,tbd,frn,frd,extra;
    uint8_t pf;
    uint16_t count;
    av_assert0(vtremote_rbuf_read_u32(&r, &w) == 0 && w==1920);
    av_assert0(vtremote_rbuf_read_u32(&r, &h) == 0 && h==1080);
    av_assert0(vtremote_rbuf_read_u8(&r, &pf) == 0 && pf==VTREMOTE_PIX_FMT_NV12);
    av_assert0(vtremote_rbuf_read_u32(&r, &tbn)==0 && tbn==1);
    av_assert0(vtremote_rbuf_read_u32(&r, &tbd)==0 && tbd==30);
    av_assert0(vtremote_rbuf_read_u32(&r, &frn)==0 && frn==30);
    av_assert0(vtremote_rbuf_read_u32(&r, &frd)==0 && frd==1);
    av_assert0(vtremote_rbuf_read_u16(&r, &count)==0 && count==2);
    const uint8_t *s; int len;
    av_assert0(vtremote_rbuf_read_str(&r, &s, &len)==0 && len==7 && !memcmp(s,"bitrate",7));
    av_assert0(vtremote_rbuf_read_str(&r, &s, &len)==0 && len==7 && !memcmp(s,"2000000",7));
    av_assert0(vtremote_rbuf_read_str(&r, &s, &len)==0 && len==3 && !memcmp(s,"gop",3));
    av_assert0(vtremote_rbuf_read_str(&r, &s, &len)==0 && len==2 && !memcmp(s,"60",2));
    av_assert0(vtremote_rbuf_read_u32(&r, &extra)==0 && extra==0);
    vtremote_wbuf_free(&b);
    return 0;
}

static int test_frame_and_packet_parse(void)
{
    uint8_t y[4] = {1,2,3,4};
    uint8_t uv[2] = {5,6};
    const uint8_t *planes[2] = { y, uv };
    uint32_t strides[2] = {2,2};
    uint32_t heights[2] = {2,1};
    uint32_t sizes[2] = {4,2};
    uint8_t hdr_data[3] = {7,8,9};
    uint8_t cc_data[2] = {10,11};
    VTRemoteSideData side_data[2] = {
        { AV_FRAME_DATA_MASTERING_DISPLAY_METADATA, sizeof(hdr_data), hdr_data },
        { AV_FRAME_DATA_A53_CC, sizeof(cc_data), cc_data },
    };
    VTRemoteWBuf b;
    vtremote_wbuf_init(&b);
    av_assert0(vtremote_payload_frame(&b, 10, 2, 1, 2, planes, strides, heights, sizes,
                                      side_data, 2) == 0);
    VTRemoteFrameView fview;
    av_assert0(vtremote_parse_frame(b.data, b.size, &fview) == 0);
    av_assert0(fview.pts == 10 && fview.duration == 2);
    av_assert0(fview.flags == 1 && fview.plane_count == 2);
    av_assert0(fview.planes[0].stride == 2 && fview.planes[0].height == 2);
    av_assert0(fview.planes[1].stride == 2 && fview.planes[1].height == 1);
    av_assert0(fview.side_data_count == 2);
    av_assert0(fview.side_data[0].type == AV_FRAME_DATA_MASTERING_DISPLAY_METADATA);
    av_assert0(fview.side_data[0].size == sizeof(hdr_data));
    av_assert0(!memcmp(fview.side_data[0].data, hdr_data, sizeof(hdr_data)));
    av_assert0(fview.side_data[1].type == AV_FRAME_DATA_A53_CC);
    av_assert0(fview.side_data[1].size == sizeof(cc_data));
    av_assert0(!memcmp(fview.side_data[1].data, cc_data, sizeof(cc_data)));

    /* Build a full message and parse PACKET view */
    VTRemoteWBuf pkt_payload;
    vtremote_wbuf_init(&pkt_payload);
    av_assert0(vtremote_wbuf_put_u64(&pkt_payload, 10) == 0);
    av_assert0(vtremote_wbuf_put_u64(&pkt_payload, 9) == 0);
    av_assert0(vtremote_wbuf_put_u64(&pkt_payload, 2) == 0);
    av_assert0(vtremote_wbuf_put_u32(&pkt_payload, 1) == 0);
    uint8_t data_bytes[3] = {0,0,1};
    av_assert0(vtremote_wbuf_put_u32(&pkt_payload, 3) == 0);
    av_assert0(vtremote_wbuf_put_bytes(&pkt_payload, data_bytes, 3) == 0);

    VTRemotePacketView view;
    av_assert0(vtremote_parse_packet(pkt_payload.data, pkt_payload.size, &view) == 0);
    av_assert0(view.pts == 10 && view.dts == 9 && view.duration == 2);
    av_assert0(view.flags == 1 && view.data_len == 3 && !memcmp(view.data, data_bytes, 3));
    av_assert0(view.side_data_count == 0);
    av_assert0(vtremote_wbuf_put_u8(&pkt_payload, 0) == 0);
    av_assert0(vtremote_wbuf_put_u8(&pkt_payload, 0) == 0);
    av_assert0(vtremote_parse_packet(pkt_payload.data, pkt_payload.size, &view) == AVERROR_INVALIDDATA);

    vtremote_wbuf_reset(&pkt_payload);
    av_assert0(vtremote_payload_packet_ex(&pkt_payload, 11, 10, 3, 1,
                                          data_bytes, sizeof(data_bytes),
                                          side_data, 2) == 0);
    av_assert0(vtremote_parse_packet(pkt_payload.data, pkt_payload.size, &view) == 0);
    av_assert0(view.pts == 11 && view.dts == 10 && view.duration == 3);
    av_assert0(view.side_data_count == 2);
    av_assert0(view.side_data[0].type == AV_FRAME_DATA_MASTERING_DISPLAY_METADATA);
    av_assert0(view.side_data[0].size == sizeof(hdr_data));
    av_assert0(!memcmp(view.side_data[0].data, hdr_data, sizeof(hdr_data)));
    av_assert0(view.side_data[1].type == AV_FRAME_DATA_A53_CC);
    av_assert0(view.side_data[1].size == sizeof(cc_data));
    av_assert0(!memcmp(view.side_data[1].data, cc_data, sizeof(cc_data)));

    av_assert0(vtremote_wbuf_put_u8(&b, 0) == 0);
    av_assert0(vtremote_wbuf_put_u8(&b, 0) == 0);
    av_assert0(vtremote_parse_frame(b.data, b.size, &fview) == AVERROR_INVALIDDATA);

    vtremote_wbuf_free(&b);
    vtremote_wbuf_free(&pkt_payload);
    return 0;
}

static int test_pix_fmt_and_cap_helpers(void)
{
    uint64_t flag = 0;

    av_assert0(!strcmp(vtremote_pix_fmt_name(VTREMOTE_PIX_FMT_NV12), "nv12"));
    av_assert0(!strcmp(vtremote_pix_fmt_name(VTREMOTE_PIX_FMT_P010), "p010"));
    av_assert0(!strcmp(vtremote_pix_fmt_name(VTREMOTE_PIX_FMT_BGRA), "bgra"));
    av_assert0(!strcmp(vtremote_pix_fmt_name(VTREMOTE_PIX_FMT_AYUV), "ayuv"));
    av_assert0(!strcmp(vtremote_pix_fmt_name(VTREMOTE_PIX_FMT_P210), "p210"));
    av_assert0(!strcmp(vtremote_pix_fmt_name(VTREMOTE_PIX_FMT_VIDEOTOOLBOX), "videotoolbox"));
    av_assert0(!strcmp(vtremote_pix_fmt_name(0xff), "unknown"));
    av_assert0(vtremote_cap_flag_for_pix_fmt(VTREMOTE_PIX_FMT_NV12) == VTREMOTE_CAP_PIXFMT_NV12);
    av_assert0(vtremote_cap_flag_for_pix_fmt(VTREMOTE_PIX_FMT_P210) == VTREMOTE_CAP_PIXFMT_P210);
    av_assert0(vtremote_cap_flag_for_pix_fmt(VTREMOTE_PIX_FMT_VIDEOTOOLBOX) == 0);

    av_assert0(vtremote_cap_flag_from_name((const uint8_t *)"pixfmt.bgra", 11, &flag) == 0);
    av_assert0(flag == VTREMOTE_CAP_PIXFMT_BGRA);
    av_assert0(vtremote_cap_flag_from_name((const uint8_t *)"side_data.v2", 12, &flag) == 0);
    av_assert0(flag == VTREMOTE_CAP_SIDE_DATA_V2);
    av_assert0(vtremote_cap_flag_from_name((const uint8_t *)"unknown", 7, &flag) == 0);
    av_assert0(flag == 0);

    return 0;
}

static int test_parse_hello_ack_caps(void)
{
    VTRemoteWBuf b;
    vtremote_wbuf_init(&b);
    av_assert0(vtremote_wbuf_put_u8(&b, 0) == 0);
    av_assert0(vtremote_wbuf_put_str(&b, "vtremoted") == 0);
    av_assert0(vtremote_wbuf_put_str(&b, "test") == 0);
    av_assert0(vtremote_wbuf_put_u8(&b, 4) == 0);
    av_assert0(vtremote_wbuf_put_str(&b, "h264") == 0);
    av_assert0(vtremote_wbuf_put_str(&b, "hevc") == 0);
    av_assert0(vtremote_wbuf_put_str(&b, "pixfmt.p210") == 0);
    av_assert0(vtremote_wbuf_put_str(&b, "hwframes.videotoolbox.output") == 0);
    av_assert0(vtremote_wbuf_put_u16(&b, 8) == 0);
    av_assert0(vtremote_wbuf_put_u16(&b, 3) == 0);

    uint8_t status = 0xff;
    const uint8_t *server_name = NULL, *server_version = NULL;
    int server_name_len = 0, server_version_len = 0;
    uint64_t caps = 0;
    uint16_t max_sessions = 0, active_sessions = 0;
    av_assert0(vtremote_caps_parse_hello_ack(b.data, b.size, &status,
                                             &server_name, &server_name_len,
                                             &server_version, &server_version_len,
                                             &caps, &max_sessions, &active_sessions) == 0);
    av_assert0(status == 0);
    av_assert0(server_name_len == 9 && !memcmp(server_name, "vtremoted", 9));
    av_assert0(server_version_len == 4 && !memcmp(server_version, "test", 4));
    av_assert0((caps & VTREMOTE_CAP_H264) != 0);
    av_assert0((caps & VTREMOTE_CAP_HEVC) != 0);
    av_assert0((caps & VTREMOTE_CAP_PIXFMT_P210) != 0);
    av_assert0((caps & VTREMOTE_CAP_HWFRAMES_VIDEOTOOLBOX_OUT) != 0);
    av_assert0((caps & VTREMOTE_CAP_PIXFMT_BGRA) == 0);
    av_assert0(max_sessions == 8);
    av_assert0(active_sessions == 3);

    vtremote_wbuf_free(&b);
    return 0;
}

int main(void)
{
    int ret = 0;
    ret |= test_roundtrip();
    ret |= test_invalid_magic();
    ret |= test_invalid_version();
    ret |= test_short_buffer();
    ret |= test_build_and_parse_hello();
    ret |= test_build_configure();
    ret |= test_frame_and_packet_parse();
    ret |= test_pix_fmt_and_cap_helpers();
    ret |= test_parse_hello_ack_caps();
    return ret ? 1 : 0;
}
