UNAME_S := $(shell uname -s)
IS_DARWIN := $(filter Darwin,$(UNAME_S))

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

FFMPEG_DIR := ffmpeg
VTREMOTED_DIR := vtremoted

FFMPEG_CONFIGURE_FLAGS ?= --enable-videotoolbox-remote --disable-debug
JOBS ?= $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 2)

VTREMOTED_LISTEN ?= 0.0.0.0:5555
VTREMOTED_LOG_LEVEL ?= 1
VTREMOTED_TOKEN ?=
VTREMOTED_SYSTEM ?=

.PHONY: build build-ffmpeg build-vtremoted install install-ffmpeg install-vtremoted clean clean-ffmpeg clean-vtremoted

build: build-ffmpeg build-vtremoted

build-ffmpeg:
	@cd $(FFMPEG_DIR) && \
	need_config=0; \
	if [ ! -f ffbuild/config.mak ]; then \
		need_config=1; \
	else \
		current=$$(sed -n 's/^FFMPEG_CONFIGURATION=//p' ffbuild/config.mak); \
		if [ "$$current" != "$(FFMPEG_CONFIGURE_FLAGS)" ]; then \
			need_config=1; \
		fi; \
	fi; \
	if [ "$$need_config" = "1" ]; then \
		echo "Reconfiguring ffmpeg (FFMPEG_CONFIGURATION mismatch or missing)"; \
		./configure $(FFMPEG_CONFIGURE_FLAGS); \
	fi
	@$(MAKE) -C $(FFMPEG_DIR) -j$(JOBS)

build-vtremoted:
ifeq ($(IS_DARWIN),Darwin)
	@cd $(VTREMOTED_DIR) && swift build -c release
else
	@echo "Skipping vtremoted build (not macOS)"
endif

install: install-ffmpeg install-vtremoted

install-ffmpeg:
	@install -d "$(BINDIR)"
	@install -m 0755 "$(FFMPEG_DIR)/ffmpeg" "$(BINDIR)/ffmpeg"

install-vtremoted:
ifeq ($(IS_DARWIN),Darwin)
	@install -d "$(BINDIR)"
	@install -m 0755 "$(VTREMOTED_DIR)/.build/release/vtremoted" "$(BINDIR)/vtremoted"
	@args="--bin $(BINDIR)/vtremoted --listen $(VTREMOTED_LISTEN) --log-level $(VTREMOTED_LOG_LEVEL)"; \
	if [ -n "$(VTREMOTED_TOKEN)" ]; then args="$$args --token $(VTREMOTED_TOKEN)"; fi; \
	if [ -n "$(VTREMOTED_SYSTEM)" ]; then args="$$args --system"; fi; \
	"$(VTREMOTED_DIR)/install_launchd.sh" $$args
else
	@echo "Skipping vtremoted install (not macOS)"
endif

clean: clean-ffmpeg clean-vtremoted

clean-ffmpeg:
	@$(MAKE) -C $(FFMPEG_DIR) clean || true

clean-vtremoted:
ifeq ($(IS_DARWIN),Darwin)
	@cd $(VTREMOTED_DIR) && swift package clean
else
	@echo "Skipping vtremoted clean (not macOS)"
endif
