include ffmpeg/ffbuild/config.mak

API_BUILD_DIR ?= /tmp/vtremote-api-regressions
API_LIBS = ffmpeg/libavformat/libavformat.a ffmpeg/libavcodec/libavcodec.a ffmpeg/libswresample/libswresample.a ffmpeg/libavutil/libavutil.a

.DEFAULT_GOAL := api-regressions
.PHONY: api-regressions
api-regressions: $(API_BUILD_DIR)/session_reset

$(API_BUILD_DIR)/%: tests/integration/%.c $(API_LIBS)
	mkdir -p $(API_BUILD_DIR)
	$(CC) $(CFLAGS) -UNDEBUG -Iffmpeg $< $(API_LIBS) $(LDFLAGS) $(EXTRALIBS-avformat) $(EXTRALIBS-avcodec) $(EXTRALIBS-swresample) $(EXTRALIBS-avutil) -o $@

$(API_BUILD_DIR)/obs_recording: tests/integration/obs_recording.cpp $(API_LIBS)
	mkdir -p $(API_BUILD_DIR)
	$(CXX) -std=c++17 -O2 -Wall -Wextra -Iffmpeg $(OBS_CFLAGS) $< $(API_LIBS) $(OBS_LIBS) $(LDFLAGS) $(EXTRALIBS-avformat) $(EXTRALIBS-avcodec) $(EXTRALIBS-swresample) $(EXTRALIBS-avutil) -o $@
