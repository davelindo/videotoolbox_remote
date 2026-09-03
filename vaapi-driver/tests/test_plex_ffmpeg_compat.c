/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "plex-ffmpeg-compat.h"

#include <stdio.h>

int main(void)
{
    if (!vtremote_plex_avcodec_version_supported(
            VTREMOTE_AV_VERSION_INT(60, 31, 102))) {
        fputs("tested Plex libavcodec version was rejected\n", stderr);
        return 1;
    }
    if (vtremote_plex_avcodec_version_supported(
            VTREMOTE_AV_VERSION_INT(60, 31, 101)) ||
        vtremote_plex_avcodec_version_supported(
            VTREMOTE_AV_VERSION_INT(60, 31, 103)) ||
        vtremote_plex_avcodec_version_supported(
            VTREMOTE_AV_VERSION_INT(61, 31, 102))) {
        fputs("untested Plex libavcodec version was accepted\n", stderr);
        return 1;
    }
    return 0;
}
