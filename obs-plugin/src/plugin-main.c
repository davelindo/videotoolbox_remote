/*
 * OBS VideoToolbox Remote Encoder Plugin
 * Main entry point
 */

#include <obs-module.h>

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("obs-vtremoted", "en-US")

extern struct obs_encoder_info vtremoted_encoder_info;

bool obs_module_load(void) {
  obs_register_encoder(&vtremoted_encoder_info);
  blog(LOG_INFO, "[vtremoted] Plugin loaded");
  return true;
}

void obs_module_unload(void) { blog(LOG_INFO, "[vtremoted] Plugin unloaded"); }

const char *obs_module_name(void) { return "VideoToolbox Remote Encoder"; }

const char *obs_module_description(void) {
  return "Remote H.264/HEVC encoding via VideoToolbox";
}
