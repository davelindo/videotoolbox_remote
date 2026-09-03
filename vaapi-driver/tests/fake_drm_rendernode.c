/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * Test-only libdrm interposer.  It lets stock FFmpeg/libva exercise a VA
 * driver plugin against a regular file in CI environments without /dev/dri.
 * Production deployments use a genuine render node (for v1, normally vgem).
 */
#define _POSIX_C_SOURCE 200809L
#include <stdlib.h>
#include <string.h>

typedef struct TestDRMVersion {
    int version_major;
    int version_minor;
    int version_patchlevel;
    int name_len;
    char *name;
    int date_len;
    char *date;
    int desc_len;
    char *desc;
} TestDRMVersion;

int drmGetNodeTypeFromFd(int fd) {
    (void)fd;
    return 2; /* DRM_NODE_RENDER */
}

TestDRMVersion *drmGetVersion(int fd) {
    TestDRMVersion *version;
    (void)fd;
    version = (TestDRMVersion *)calloc(1, sizeof(*version));
    if (!version) return NULL;
    version->version_major = 1;
    version->name = strdup("vgem");
    version->date = strdup("");
    version->desc = strdup("test virtual GEM render node");
    if (!version->name || !version->date || !version->desc) {
        free(version->name);
        free(version->date);
        free(version->desc);
        free(version);
        return NULL;
    }
    version->name_len = (int)strlen(version->name);
    version->date_len = (int)strlen(version->date);
    version->desc_len = (int)strlen(version->desc);
    return version;
}

void drmFreeVersion(TestDRMVersion *version) {
    if (!version) return;
    free(version->name);
    free(version->date);
    free(version->desc);
    free(version);
}
