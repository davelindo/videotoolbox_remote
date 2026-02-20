/*
 * VTRemoted Client - C API Header
 */

#ifndef VTREMOTED_CLIENT_H
#define VTREMOTED_CLIENT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VTRemotedClient VTRemotedClient;

VTRemotedClient *vtremoted_client_create(void);
void vtremoted_client_destroy(VTRemotedClient *client);

bool vtremoted_client_connect(VTRemotedClient *client, const char *host,
                              int port, const char *token);
void vtremoted_client_disconnect(VTRemotedClient *client);
bool vtremoted_client_is_connected(VTRemotedClient *client);

bool vtremoted_client_configure(VTRemotedClient *client, uint32_t width,
                                uint32_t height, uint8_t pix_fmt,
                                uint32_t time_base_num, uint32_t time_base_den,
                                uint32_t fr_num, uint32_t fr_den, int bitrate,
                                int gop, int wire_compression);

const uint8_t *vtremoted_client_get_extradata(VTRemotedClient *client,
                                              size_t *size);

bool vtremoted_client_send_frame(VTRemotedClient *client, int64_t pts,
                                 int64_t duration, uint8_t plane_count,
                                 const uint8_t *const *planes,
                                 const uint32_t *strides,
                                 const uint32_t *heights,
                                 const uint32_t *sizes);

bool vtremoted_client_receive_packet(VTRemotedClient *client,
                                     const uint8_t **out_data, size_t *out_size,
                                     int64_t *out_pts, int64_t *out_dts,
                                     bool *out_keyframe);

#ifdef __cplusplus
}
#endif

#endif /* VTREMOTED_CLIENT_H */
