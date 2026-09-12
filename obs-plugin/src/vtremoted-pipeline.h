#pragma once
#include "vtremoted-client.h"

#ifdef __cplusplus
extern "C" {
#endif
typedef struct VTRemotedPipeline VTRemotedPipeline;
/* The caller owns the configured client and destroys the pipeline first. */
VTRemotedPipeline *vtremoted_pipeline_create(VTRemotedClient *client, size_t frame_bytes);
void vtremoted_pipeline_destroy(VTRemotedPipeline *pipeline);
bool vtremoted_pipeline_submit(VTRemotedPipeline *pipeline, int64_t pts,
                               const uint8_t *const planes[2], const uint32_t strides[2],
                               const uint32_t heights[2], const uint32_t sizes[2]);
void vtremoted_pipeline_flush(VTRemotedPipeline *pipeline);
VTRReceiveResult vtremoted_pipeline_receive(VTRemotedPipeline *pipeline, const uint8_t **data,
                                            size_t *size, int64_t *pts, int64_t *dts,
                                            bool *keyframe);
void vtremoted_pipeline_get_error(VTRemotedPipeline *pipeline, char *error, size_t size);
#ifdef __cplusplus
}
#endif
