UNAME_S := $(shell uname -s)
IS_DARWIN := $(filter Darwin,$(UNAME_S))

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

FFMPEG_DIR := ffmpeg
VTREMOTED_DIR := vtremoted

ifeq ($(IS_DARWIN),Darwin)
ifeq ($(origin CC),default)
CC := $(shell xcrun -f clang 2>/dev/null || echo clang)
endif
ifeq ($(origin CXX),default)
CXX := $(shell xcrun -f clang++ 2>/dev/null || echo clang++)
endif
OBJC ?= $(CC)
OBJCC ?= $(CXX)
SDKROOT ?= $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)
MACOSX_DEPLOYMENT_TARGET ?= $(shell sw_vers -productVersion 2>/dev/null | awk -F. '{print $$1"."$$2}')
endif

ifeq ($(IS_DARWIN),Darwin)
FFMPEG_CONFIGURE_FLAGS ?= --enable-videotoolbox --enable-videotoolbox-remote --enable-libzstd --disable-debug --disable-response-files
else
FFMPEG_CONFIGURE_FLAGS ?= --enable-videotoolbox-remote --enable-libzstd --disable-debug --disable-response-files
endif
JOBS ?= $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 2)

VTREMOTED_LISTEN ?= 0.0.0.0:5555
VTREMOTED_LOG_LEVEL ?= 1
VTREMOTED_TOKEN ?=
VTREMOTED_SYSTEM ?=

.PHONY: build build-ffmpeg build-vtremoted install install-ffmpeg install-vtremoted clean clean-ffmpeg clean-vtremoted

build: build-ffmpeg build-vtremoted

build-ffmpeg:
	cd $(FFMPEG_DIR) && \
	config_flags="$(FFMPEG_CONFIGURE_FLAGS)"; \
	if [ "$(IS_DARWIN)" = "Darwin" ]; then \
		if ! printf "%s" "$$config_flags" | grep -qE '(^|[[:space:]])--(enable|disable)-videotoolbox($|[[:space:]])'; then \
			config_flags="$$config_flags --enable-videotoolbox"; \
		fi; \
		if ! printf "%s" "$$config_flags" | grep -q -- "--sysroot="; then \
			if [ -n "$(SDKROOT)" ]; then \
				config_flags="$$config_flags --sysroot=$(SDKROOT)"; \
			else \
				echo "ERROR: SDKROOT is empty; run 'xcrun --sdk macosx --show-sdk-path' or set SDKROOT" >&2; \
				exit 1; \
			fi; \
		fi; \
		sysroot_flag="-isysroot $(SDKROOT)"; \
		framework_flag="-F$(SDKROOT)/System/Library/Frameworks"; \
		cppflags="$(CPPFLAGS)"; \
		cflags="$(CFLAGS)"; \
		objcflags="$(OBJCFLAGS)"; \
		ldflags="$(LDFLAGS)"; \
		if ! printf "%s" "$$cppflags" | grep -q -- "-isysroot"; then \
			cppflags="$$cppflags $$sysroot_flag"; \
		fi; \
		if ! printf "%s" "$$cflags" | grep -q -- "-isysroot"; then \
			cflags="$$cflags $$sysroot_flag"; \
		fi; \
		if ! printf "%s" "$$objcflags" | grep -q -- "-isysroot"; then \
			objcflags="$$objcflags $$sysroot_flag"; \
		fi; \
		if ! printf "%s" "$$ldflags" | grep -q -- "-isysroot"; then \
			ldflags="$$ldflags $$sysroot_flag"; \
		fi; \
		if ! printf "%s" "$$cppflags" | grep -q -- "-F"; then \
			cppflags="$$cppflags $$framework_flag"; \
		fi; \
		if ! printf "%s" "$$cflags" | grep -q -- "-F"; then \
			cflags="$$cflags $$framework_flag"; \
		fi; \
		if ! printf "%s" "$$objcflags" | grep -q -- "-F"; then \
			objcflags="$$objcflags $$framework_flag"; \
		fi; \
		if ! printf "%s" "$$ldflags" | grep -q -- "-F"; then \
			ldflags="$$ldflags $$framework_flag"; \
		fi; \
	fi; \
	need_config=0; \
	if [ ! -f ffbuild/config.mak ]; then \
		need_config=1; \
	else \
		current=$$(sed -n 's/^FFMPEG_CONFIGURATION=//p' ffbuild/config.mak); \
		if [ "$$current" != "$$config_flags" ]; then \
			need_config=1; \
		fi; \
	fi; \
	if [ "$$need_config" = "1" ]; then \
		echo "Reconfiguring ffmpeg (FFMPEG_CONFIGURATION mismatch or missing)"; \
		env darwin=yes CC="$(CC)" CXX="$(CXX)" OBJC="$(OBJC)" OBJCC="$(OBJCC)" SDKROOT="$(SDKROOT)" MACOSX_DEPLOYMENT_TARGET="$(MACOSX_DEPLOYMENT_TARGET)" \
		CPPFLAGS="$$cppflags" CFLAGS="$$cflags" OBJCFLAGS="$$objcflags" LDFLAGS="$$ldflags" \
		./configure $$config_flags; \
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
