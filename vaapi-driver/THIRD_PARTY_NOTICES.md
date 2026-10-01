# Third-party notices

The VA-API driver is built against the public libva headers and links to the
LZ4 and Zstandard libraries. Their licenses and source are maintained by their
respective upstream projects. No libva source or headers are copied into this
repository or its binary bundle.

The Plex preload module includes FFmpeg 6.1.1 coded-bitstream and H.264 parser
sources from the official, checksum-verified SDK. These sources retain their
upstream LGPL-2.1-or-later notices; the SDK is available at
https://ffmpeg.org/releases/ffmpeg-6.1.1.tar.xz. The module also includes this
repository's FFmpeg transcode filter and wire protocol implementation.

The project source is licensed under LGPL-2.1-or-later as stated in the file
headers and the repository license documentation.
