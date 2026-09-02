# Plex playback-transcode integration

The supported Plex path is software decode/filter followed by VA-API upload and
remote H.264 or HEVC encoding. It does not claim VA-API decode, scaling,
deinterlace, tone mapping, OpenCL interop, or DMA-BUF import/export.

The example image is pinned to official Plex Media Server
`1.43.3.10896-cb3ebc72d` for amd64, including its platform digest. Build it
from the driver directory:

```bash
docker build -f docker/Dockerfile.plex \
  --build-arg VTREMOTE_VERSION="$(git -C .. describe --tags --always)" \
  -t plex-vtremote .
```

The Linux host must provide a render node. With no physical GPU, load vgem on
the host and pass its render node into the container:

```bash
sudo modprobe vgem
ls -l /dev/dri/renderD*
```

Use `docker/docker-compose.plex.yml.example` as a merge fragment. Set
`VTREMOTE_HOST`, `RENDER_DEVICE`, and `RENDER_GID`; set `PLEX_CLAIM` or reuse an
existing Plex configuration as required by the official image. The isolated
`iHD` alias is provided because Plex can explicitly request that driver name.
It does not replace a host Intel driver.

First validate the exact Plex Transcoder and libva stack without claiming the
server. This test supplies raw frames to Plex's bundled Transcoder, encodes
H.264, HEVC Main, and HEVC Main 10 through VA-API, and requires no Plex token,
library, downloaded codec modules, or Plex Pass entitlement:

```bash
PLEX_CONTAINER=plex \
RENDER_DEVICE=/dev/dri/renderD128 \
  ./scripts/plex-transcoder-vaapi-smoke.sh
```

This is the primary deterministic Plex compatibility smoke test. It validates
the bundled Plex Transcoder, its libva integration, the render node, the
VTRemote driver, the network transport, and the remote VideoToolbox encoder.

As a separate product-policy acceptance test, enable hardware-accelerated
encoding in a claimed Plex Pass server, but leave decode and tone mapping on
software. Then run `scripts/plex-playback-smoke.sh`; it calls Plex Media
Server's universal playback endpoint, downloads an HLS segment, and requires a
new VTRemote driver log entry from the container.

```bash
PLEX_URL=http://127.0.0.1:32400 \
PLEX_TOKEN=... \
PLEX_RATING_KEY=12345 \
PLEX_CONTAINER=plex \
  ./scripts/plex-playback-smoke.sh
```

Use an SDR item for H.264 playback validation and a 10-bit item when validating
HEVC Main 10. The claimed-server test proves PMS selected the driver during a
real playback request; the unclaimed-server test proves the underlying Plex
Transcoder/VA-API integration independently of account policy.
