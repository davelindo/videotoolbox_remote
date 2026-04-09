#!/usr/bin/env bash
set -euo pipefail

# Regression coverage for vtremote_transcode signaling:
# 1. Explicit override path keeps hvc1 + HDR signaling and writes container colr.
# 2. Source metadata is preserved without explicit output overrides.
# 3. Alias spellings and colorspace=rgb (enum 0) survive the CLI -> BSF bridge.
# 4. Invalid numeric color enums fail on both the mux bridge and direct BSF path.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FFMPEG_BIN="${FFMPEG_BIN:-${ROOT}/ffmpeg/ffmpeg}"
FFPROBE_BIN="${FFPROBE_BIN:-${ROOT}/ffmpeg/ffprobe}"
SERVER_TOKEN=${SERVER_TOKEN:-}
SERVER_ADDR=${SERVER_ADDR:-}

if [[ -z "$SERVER_ADDR" ]]; then
  PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
  SERVER_ADDR="127.0.0.1:${PORT}"
fi

SERVER_HOST="${SERVER_ADDR%:*}"
SERVER_PORT="${SERVER_ADDR##*:}"
FIXTURE_DIR="${ROOT}/tests/integration/mock_vtremoted/fixtures"
HVCC_FIXTURE="${FIXTURE_DIR}/hevc_main10_bt2020_pq_hvcc.hex"
PACKET_FIXTURE="${FIXTURE_DIR}/hevc_main10_bt2020_pq_packet.hex"

for required in "$FFMPEG_BIN" "$FFPROBE_BIN" "$HVCC_FIXTURE" "$PACKET_FIXTURE"; do
  if [[ ! -e "$required" ]]; then
    echo "ERROR: required artifact missing: $required" >&2
    exit 1
  fi
done

have_encoder() {
  local enc="$1"
  "$FFMPEG_BIN" -encoders 2>/dev/null | grep -w "$enc" >/dev/null
}

ENCODER=""
PIX_FMT="yuv420p"
ENC_ARGS=()
if have_encoder "libopenh264"; then
  ENCODER="libopenh264"
elif have_encoder "libx264"; then
  ENCODER="libx264"
  ENC_ARGS=( -preset ultrafast -tune zerolatency )
elif have_encoder "h264_videotoolbox"; then
  ENCODER="h264_videotoolbox"
  PIX_FMT="nv12"
  ENC_ARGS=( -allow_sw 1 -color_range:v limited )
else
  echo "ERROR: no local H.264 encoder available (need libopenh264/libx264/h264_videotoolbox)" >&2
  exit 1
fi

TMPDIR=$(mktemp -d /tmp/mock_vtremoted_hvc1_hdr.XXXXXX)
trap 'rm -rf "$TMPDIR"; kill "${SERVER_PID:-}" 2>/dev/null || true' EXIT

assert_probe_fields() {
  local target="$1"
  shift
  local output
  output=$("$FFPROBE_BIN" -hide_banner -v error \
    -show_entries stream=codec_tag_string,color_range,color_space,color_transfer,color_primaries,profile,pix_fmt \
    -of default=nw=1 \
    "$target")
  for expected in "$@"; do
    if ! grep -Fx "$expected" <<<"$output" >/dev/null; then
      echo "ERROR: missing expected probe field '$expected' for $target" >&2
      echo "$output" >&2
      exit 1
    fi
  done
}

assert_init_segment_colr() {
  local init_mp4="$1"
  python3 - "$init_mp4" <<'PY'
import pathlib
import struct
import sys

path = pathlib.Path(sys.argv[1])
data = path.read_bytes()
idx = data.find(b"nclx")
if idx < 0:
    raise SystemExit(f"ERROR: missing nclx colr box in {path}")
if idx + 11 > len(data):
    raise SystemExit(f"ERROR: truncated nclx payload in {path}")
primaries, transfer, matrix = struct.unpack(">HHH", data[idx + 4:idx + 10])
full_range = data[idx + 10] >> 7
expected = (9, 16, 9, 0)
actual = (primaries, transfer, matrix, full_range)
if actual != expected:
    raise SystemExit(
        f"ERROR: unexpected nclx values in {path}: "
        f"got={actual} expected={expected}"
    )
PY
}

start_mock_server() {
  local server_log="$1"
  shift
  local server_cmd=(
    python3 "${ROOT}/tests/integration/mock_vtremoted/mock_vtremoted.py"
    --listen "$SERVER_ADDR"
    --packet-reply packet
    --configure-extradata-hex-file "$HVCC_FIXTURE"
    --packet-data-hex-file "$PACKET_FIXTURE"
    --once
  )
  if [[ -n "$SERVER_TOKEN" ]]; then
    server_cmd+=( --token "$SERVER_TOKEN" )
  fi
  server_cmd+=( "$@" )
  "${server_cmd[@]}" >"$server_log" 2>&1 &
  SERVER_PID=$!
  sleep 0.2
}

wait_mock_server() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    wait "$SERVER_PID"
    unset SERVER_PID
  fi
}

stop_mock_server() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    unset SERVER_PID
  fi
}

create_h264_input() {
  local output="$1"
  "$FFMPEG_BIN" -hide_banner -y \
    -f lavfi -i testsrc2=size=64x64:rate=5 -t 1 -pix_fmt "$PIX_FMT" \
    -c:v "$ENCODER" "${ENC_ARGS[@]+"${ENC_ARGS[@]}"}" -bf 0 -g 10 \
    "$output" > /dev/null 2>>"${TMPDIR}/ffmpeg.log"
}

create_hevc_source_mp4() {
  local raw_hevc="$1"
  local output_mp4="$2"

  python3 - "$PACKET_FIXTURE" "$raw_hevc" <<'PY'
from pathlib import Path
import sys

fixture = Path(sys.argv[1])
output = Path(sys.argv[2])
payload = bytes.fromhex("".join(fixture.read_text(encoding="utf-8").split()))
output.write_bytes(payload)
PY

  "$FFMPEG_BIN" -hide_banner -y \
    -fflags +genpts \
    -f hevc -i "$raw_hevc" \
    -map 0:v:0 \
    -c:v copy \
    -tag:v hvc1 \
    -color_range limited \
    -colorspace bt2020nc \
    -color_trc smpte2084 \
    -color_primaries bt2020 \
    -movflags +write_colr \
    "$output_mp4" > /dev/null 2>>"${TMPDIR}/ffmpeg.log"
}

run_override_case() {
  local case_dir="${TMPDIR}/override"
  local server_log="${case_dir}/server.log"
  local input_mp4="${case_dir}/input.mp4"
  local out_m3u8="${case_dir}/master.m3u8"
  local transcode_args=()
  mkdir -p "$case_dir"

  create_h264_input "$input_mp4"
  start_mock_server "$server_log" \
    --expect-color-range 1 \
    --expect-colorspace 9 \
    --expect-color-primaries 9 \
    --expect-color-trc 16
  if [[ -n "$SERVER_TOKEN" ]]; then
    transcode_args+=( -vt_remote_token "$SERVER_TOKEN" )
  fi

  "$FFMPEG_BIN" -hide_banner -y \
    -i "$input_mp4" \
    -map 0:v:0 \
    -c:v copy \
    -vt_remote_transcode:v:0 \
    -vt_remote_host "$SERVER_HOST" \
    -vt_remote_port "$SERVER_PORT" \
    -vt_remote_out_codec hevc \
    "${transcode_args[@]}" \
    -pix_fmt:v p010le \
    -color_range:v limited \
    -colorspace:v bt2020_ncl \
    -color_trc:v smpte2084 \
    -color_primaries:v bt2020 \
    -tag:v hvc1 \
    -movflags +write_colr \
    -f hls \
    -hls_time 1 \
    -hls_list_size 0 \
    -hls_segment_type fmp4 \
    -hls_flags independent_segments \
    -hls_fmp4_init_filename init.mp4 \
    "$out_m3u8" > /dev/null 2>>"${TMPDIR}/ffmpeg.log"

  wait_mock_server

  assert_probe_fields "$out_m3u8" \
    "profile=Main 10" \
    "codec_tag_string=hvc1" \
    "pix_fmt=yuv420p10le" \
    "color_range=tv" \
    "color_space=bt2020nc" \
    "color_transfer=smpte2084" \
    "color_primaries=bt2020"
  assert_probe_fields "${case_dir}/init.mp4" "codec_tag_string=hvc1"
  assert_init_segment_colr "${case_dir}/init.mp4"
}

run_preserve_source_case() {
  local case_dir="${TMPDIR}/preserve_source"
  local server_log="${case_dir}/server.log"
  local raw_hevc="${case_dir}/source.h265"
  local source_mp4="${case_dir}/source_hdr.mp4"
  local out_m3u8="${case_dir}/master.m3u8"
  local transcode_args=()
  mkdir -p "$case_dir"

  create_hevc_source_mp4 "$raw_hevc" "$source_mp4"
  assert_probe_fields "$source_mp4" \
    "profile=Main 10" \
    "codec_tag_string=hvc1" \
    "pix_fmt=yuv420p10le" \
    "color_range=tv" \
    "color_space=bt2020nc" \
    "color_transfer=smpte2084" \
    "color_primaries=bt2020"
  assert_init_segment_colr "$source_mp4"

  start_mock_server "$server_log" \
    --expect-color-range 1 \
    --expect-colorspace 9 \
    --expect-color-primaries 9 \
    --expect-color-trc 16
  if [[ -n "$SERVER_TOKEN" ]]; then
    transcode_args+=( -vt_remote_token "$SERVER_TOKEN" )
  fi

  "$FFMPEG_BIN" -hide_banner -y \
    -i "$source_mp4" \
    -map 0:v:0 \
    -c:v copy \
    -vt_remote_transcode:v:0 \
    -vt_remote_host "$SERVER_HOST" \
    -vt_remote_port "$SERVER_PORT" \
    -vt_remote_out_codec hevc \
    "${transcode_args[@]}" \
    -pix_fmt:v p010le \
    -movflags +write_colr \
    -f hls \
    -hls_time 1 \
    -hls_list_size 0 \
    -hls_segment_type fmp4 \
    -hls_flags independent_segments \
    -hls_fmp4_init_filename init.mp4 \
    "$out_m3u8" > /dev/null 2>>"${TMPDIR}/ffmpeg.log"

  wait_mock_server

  assert_probe_fields "$out_m3u8" \
    "profile=Main 10" \
    "codec_tag_string=hvc1" \
    "pix_fmt=yuv420p10le" \
    "color_range=tv" \
    "color_space=bt2020nc" \
    "color_transfer=smpte2084" \
    "color_primaries=bt2020"
  assert_probe_fields "${case_dir}/init.mp4" "codec_tag_string=hvc1"
  assert_init_segment_colr "${case_dir}/init.mp4"
}

run_rgb_alias_case() {
  local case_dir="${TMPDIR}/rgb_alias"
  local server_log="${case_dir}/server.log"
  local input_mp4="${case_dir}/input.mp4"
  local transcode_args=()
  mkdir -p "$case_dir"

  create_h264_input "$input_mp4"
  start_mock_server "$server_log" \
    --expect-color-range 2 \
    --expect-colorspace 0
  if [[ -n "$SERVER_TOKEN" ]]; then
    transcode_args+=( -vt_remote_token "$SERVER_TOKEN" )
  fi

  "$FFMPEG_BIN" -hide_banner -y \
    -i "$input_mp4" \
    -map 0:v:0 \
    -c:v copy \
    -vt_remote_transcode:v:0 \
    -vt_remote_host "$SERVER_HOST" \
    -vt_remote_port "$SERVER_PORT" \
    -vt_remote_out_codec hevc \
    "${transcode_args[@]}" \
    -pix_fmt:v p010le \
    -color_range:v full \
    -colorspace:v rgb \
    -f null - > /dev/null 2>>"${TMPDIR}/ffmpeg.log"

  wait_mock_server
}

run_invalid_numeric_case() {
  local case_dir="${TMPDIR}/invalid_numeric"
  local server_log="${case_dir}/server.log"
  local ffmpeg_log="${case_dir}/ffmpeg.log"
  local input_mp4="${case_dir}/input.mp4"
  local transcode_args=()
  mkdir -p "$case_dir"

  create_h264_input "$input_mp4"
  start_mock_server "$server_log"
  if [[ -n "$SERVER_TOKEN" ]]; then
    transcode_args+=( -vt_remote_token "$SERVER_TOKEN" )
  fi

  if "$FFMPEG_BIN" -hide_banner -y \
    -i "$input_mp4" \
    -map 0:v:0 \
    -c:v copy \
    -vt_remote_transcode:v:0 \
    -vt_remote_host "$SERVER_HOST" \
    -vt_remote_port "$SERVER_PORT" \
    -vt_remote_out_codec hevc \
    "${transcode_args[@]}" \
    -pix_fmt:v p010le \
    -colorspace:v 999 \
    -f null - > /dev/null 2>"$ffmpeg_log"; then
    echo "ERROR: invalid numeric colorspace unexpectedly succeeded" >&2
    stop_mock_server
    exit 1
  fi

  if ! grep -F "Invalid colorspace '999' for vt_remote_transcode" "$ffmpeg_log" >/dev/null; then
    echo "ERROR: missing invalid numeric colorspace failure" >&2
    cat "$ffmpeg_log" >&2
    stop_mock_server
    exit 1
  fi

  stop_mock_server
}

run_invalid_direct_bsf_case() {
  local case_dir="${TMPDIR}/invalid_direct_bsf"
  local server_log="${case_dir}/server.log"
  local ffmpeg_log="${case_dir}/ffmpeg.log"
  local input_mp4="${case_dir}/input.mp4"
  local bsf_spec=
  mkdir -p "$case_dir"

  create_h264_input "$input_mp4"
  start_mock_server "$server_log"

  bsf_spec="vtremote_transcode=vt_remote_host=${SERVER_HOST}:vt_remote_port=${SERVER_PORT}:vt_remote_colorspace=999"
  if [[ -n "$SERVER_TOKEN" ]]; then
    bsf_spec="${bsf_spec}:vt_remote_token=${SERVER_TOKEN}"
  fi

  if "$FFMPEG_BIN" -hide_banner -y \
    -i "$input_mp4" \
    -map 0:v:0 \
    -c:v copy \
    -bsf:v "$bsf_spec" \
    -f null - > /dev/null 2>"$ffmpeg_log"; then
    echo "ERROR: invalid direct BSF colorspace unexpectedly succeeded" >&2
    stop_mock_server
    exit 1
  fi

  if ! grep -F "Invalid colorspace 999 for vtremote_transcode" "$ffmpeg_log" >/dev/null; then
    echo "ERROR: missing invalid direct BSF colorspace failure" >&2
    cat "$ffmpeg_log" >&2
    stop_mock_server
    exit 1
  fi

  stop_mock_server
}

run_non_mp4_mux_case() {
  local case_dir="${TMPDIR}/non_mp4_mux"
  local server_log="${case_dir}/server.log"
  local ffmpeg_log="${case_dir}/ffmpeg.log"
  local input_mp4="${case_dir}/input.mp4"
  local out_flv="${case_dir}/output.flv"
  local transcode_args=()
  mkdir -p "$case_dir"

  create_h264_input "$input_mp4"
  start_mock_server "$server_log" --packet-reply packet
  if [[ -n "$SERVER_TOKEN" ]]; then
    transcode_args+=( -vt_remote_token "$SERVER_TOKEN" )
  fi

  "$FFMPEG_BIN" -hide_banner -y \
    -i "$input_mp4" \
    -map 0:v:0 \
    -c:v copy \
    -vt_remote_transcode:v:0 \
    -vt_remote_host "$SERVER_HOST" \
    -vt_remote_port "$SERVER_PORT" \
    "${transcode_args[@]}" \
    -f flv "$out_flv" > /dev/null 2>"$ffmpeg_log"

  wait_mock_server

  if [[ ! -s "$out_flv" ]]; then
    echo "ERROR: non-MP4 mux output was not written" >&2
    cat "$ffmpeg_log" >&2
    exit 1
  fi
}

run_override_case
run_preserve_source_case
run_rgb_alias_case
run_invalid_numeric_case
run_invalid_direct_bsf_case
run_non_mp4_mux_case

echo "OK: vtremote_transcode preserved hvc1 + HDR signaling; logs under ${TMPDIR}"
