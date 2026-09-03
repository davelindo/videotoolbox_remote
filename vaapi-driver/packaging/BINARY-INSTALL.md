# Prebuilt Linux x86_64 bundle

The archive contains the runtime under `/opt/vtremote-vaapi`, the experimental
static C SDK, public headers, pkg-config metadata, the Plex Transcoder wrapper
and preload module, documentation, checksums, and an installer. The modules
require glibc, liblz4, and libzstd at runtime. The VA-API driver is built
against VA-API 1.22 headers but does not link to libva.

Install the dependencies with your distribution, then run:

```bash
sudo ./install-binary.sh
sudo modprobe vgem
```

The installer refuses to overwrite an existing `/opt/vtremote-vaapi` tree.
After installation, set `LIBVA_DRIVERS_PATH`, `LIBVA_DRIVER_NAME`, and the
required `VTREMOTE_HOST` as printed by the installer. Use the iHD alias only in
this isolated directory for a controlled Plex process.
