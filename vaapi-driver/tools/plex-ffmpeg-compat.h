/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef VTREMOTE_PLEX_FFMPEG_COMPAT_H
#define VTREMOTE_PLEX_FFMPEG_COMPAT_H

#include <stdbool.h>
#include <stdint.h>

#define VTREMOTE_AV_VERSION_INT(major, minor, micro) \
    (((uint32_t)(major) << 16) | ((uint32_t)(minor) << 8) | (uint32_t)(micro))

/* Supported Plex FFmpeg 6.1 bundles report this exact public libavcodec
 * version. The injected module also depends on their private FFBSFContext
 * layout, so a major-only check is not sufficient. */
static inline bool vtremote_plex_avcodec_version_supported(uint32_t version)
{
    switch (version) {
    case VTREMOTE_AV_VERSION_INT(60, 31, 102):
        return true;
    default:
        return false;
    }
}

#endif
