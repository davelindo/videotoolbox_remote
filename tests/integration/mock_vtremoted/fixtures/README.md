# HEVC HDR Fixture Notes

These files are golden protocol payloads for the mock `vtremoted` integration tests:

- `hevc_main10_bt2020_pq_hvcc.hex`: the `hvcC`/extradata blob returned in `CONFIGURE_ACK`
- `hevc_main10_bt2020_pq_packet.hex`: a single Annex B keyframe packet returned in `PACKET`
- `h264_test_avcc.hex`: minimal synthetic `avcC` SPS/PPS data for protocol tests

Required properties:

- codec: HEVC
- profile: Main 10
- codec tag when muxed into MP4: `hvc1`
- color range: limited / TV
- color space: `bt2020nc`
- color transfer: `smpte2084`
- color primaries: `bt2020`

Quick verification after muxing the packet into MP4 with `-tag:v hvc1 -movflags +write_colr`:

```bash
ffprobe -hide_banner -v error \
  -show_entries stream=codec_tag_string,color_range,color_space,color_transfer,color_primaries,profile,pix_fmt \
  -of default=nw=1 \
  fixture.mp4
```

Expected fields:

```text
profile=Main 10
codec_tag_string=hvc1
pix_fmt=yuv420p10le
color_range=tv
color_space=bt2020nc
color_transfer=smpte2084
color_primaries=bt2020
```

Regeneration workflow from a replacement one-frame HEVC Main 10 BT.2020 PQ MP4:

1. Verify the candidate input with the `ffprobe` command above.
2. Extract the `hvcC` extradata:

```bash
ffprobe -hide_banner -v error -select_streams v:0 -show_entries stream=extradata -show_data \
  -of default=nw=1 replacement.mp4 \
  | awk '
      /^extradata=$/ { capture = 1; next }
      capture && /^0x/ {
        sub(/^0x[0-9a-f]+: /, "")
        sub(/ .*/, "")
        printf "%s", $0
      }
      END { printf "\n" }
    ' \
  > hevc_main10_bt2020_pq_hvcc.hex
```

3. Extract the first Annex B packet:

```bash
ffmpeg -hide_banner -v error -i replacement.mp4 -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb \
  -frames:v 1 -f hevc - \
  | xxd -p -c 32 \
  > hevc_main10_bt2020_pq_packet.hex
```

4. Re-run `tests/integration/run_mock_transcode_hvc1_hdr_signaling.sh`.
