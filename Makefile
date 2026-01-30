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
MACOSX_SDK_VERSION := $(shell xcrun --sdk macosx --show-sdk-version 2>/dev/null)
MACOSX_DEPLOYMENT_TARGET ?= $(if $(MACOSX_SDK_VERSION),$(MACOSX_SDK_VERSION),$(shell sw_vers -productVersion 2>/dev/null | awk -F. '{print $$1"."$$2}'))
ifneq ($(wildcard /opt/homebrew/bin/pkg-config),)
PKG_CONFIG ?= /opt/homebrew/bin/pkg-config
PKG_CONFIG_PATH ?= /opt/homebrew/lib/pkgconfig:/opt/homebrew/share/pkgconfig
endif
endif

ifeq ($(IS_DARWIN),Darwin)
FFMPEG_CC := $(shell xcrun -f clang 2>/dev/null || echo clang)
FFMPEG_CXX := $(shell xcrun -f clang++ 2>/dev/null || echo clang++)
else
FFMPEG_CC ?= $(CC)
FFMPEG_CXX ?= $(CXX)
endif
FFMPEG_OBJC := $(FFMPEG_CC)
FFMPEG_OBJCC := $(FFMPEG_CC)

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
.SILENT: build-ffmpeg

build: build-ffmpeg build-vtremoted

build-ffmpeg:
	cd $(FFMPEG_DIR) && \
	config_flags="$(FFMPEG_CONFIGURE_FLAGS)"; \
	sdkroot="$(SDKROOT)"; \
	cc="$(FFMPEG_CC)"; \
	cxx="$(FFMPEG_CXX)"; \
	objcc="$(FFMPEG_OBJCC)"; \
	if [ "$(IS_DARWIN)" = "Darwin" ]; then \
		if ! printf "%s" "$$config_flags" | grep -q -- "--cc="; then \
			config_flags="$$config_flags --cc=$$cc"; \
		fi; \
		if ! printf "%s" "$$config_flags" | grep -q -- "--cxx="; then \
			config_flags="$$config_flags --cxx=$$cxx"; \
		fi; \
		if ! printf "%s" "$$config_flags" | grep -q -- "--objcc="; then \
			config_flags="$$config_flags --objcc=$$objcc"; \
		fi; \
		if [ -z "$$sdkroot" ]; then \
			sdkroot=$$(xcrun --sdk macosx --show-sdk-path 2>/dev/null); \
		fi; \
		if ! printf "%s" "$$config_flags" | grep -qE '(^|[[:space:]])--(enable|disable)-videotoolbox($|[[:space:]])'; then \
			config_flags="$$config_flags --enable-videotoolbox"; \
		fi; \
		if [ -n "$$sdkroot" ] && ! printf "%s" "$$config_flags" | grep -q -- "--sysroot="; then \
			config_flags="$$config_flags --sysroot=$$sdkroot"; \
		fi; \
		sysroot_flag="-isysroot$$sdkroot"; \
		framework_flag="-F$$sdkroot/System/Library/Frameworks"; \
		if [ -x /opt/homebrew/bin/pkg-config ] && ! printf "%s" "$$config_flags" | grep -q -- "--pkg-config="; then \
			config_flags="$$config_flags --pkg-config=/opt/homebrew/bin/pkg-config"; \
		fi; \
		if ! printf "%s" "$$config_flags" | grep -q -- "--host-cc="; then \
			config_flags="$$config_flags --host-cc=$$cc"; \
		fi; \
		if ! printf "%s" "$$config_flags" | grep -q -- "--host-cflags="; then \
			config_flags="$$config_flags --host-cflags=$$sysroot_flag"; \
		fi; \
		if ! printf "%s" "$$config_flags" | grep -q -- "--host-ldflags="; then \
			config_flags="$$config_flags --host-ldflags=$$sysroot_flag"; \
		fi; \
		cppflags="$(CPPFLAGS)"; \
		cflags="$(CFLAGS)"; \
		objcflags="$(OBJCFLAGS)"; \
		ldflags="$(LDFLAGS)"; \
		if [ -n "$$sdkroot" ]; then \
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
		else \
			echo "WARN: SDKROOT not set; building without explicit sysroot (install Xcode for local VideoToolbox)" >&2; \
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
		env darwin=yes CC="$$cc" CXX="$$cxx" OBJCC="$$objcc" SDKROOT="$$sdkroot" MACOSX_DEPLOYMENT_TARGET="$(MACOSX_DEPLOYMENT_TARGET)" \
		PKG_CONFIG="$(PKG_CONFIG)" PKG_CONFIG_PATH="$(PKG_CONFIG_PATH)" \
		CPPFLAGS="$$cppflags" CFLAGS="$$cflags" OBJCFLAGS="$$objcflags" LDFLAGS="$$ldflags" \
		./configure $$config_flags; \
	fi
	@$(MAKE) -C $(FFMPEG_DIR) -j$(JOBS)

build-vtremoted:
ifeq ($(IS_DARWIN),Darwin)
	@cd $(VTREMOTED_DIR) && \
	path="$$PATH"; \
	if [ -n "$(PKG_CONFIG)" ]; then \
		pkg_dir=$$(dirname "$(PKG_CONFIG)"); \
		case ":$$path:" in *":$$pkg_dir:"*) ;; *) path="$$pkg_dir:$$path";; esac; \
	fi; \
	if [ -n "$(SDKROOT)" ]; then export SDKROOT="$(SDKROOT)"; fi; \
	if [ -n "$(PKG_CONFIG)" ]; then export PKG_CONFIG="$(PKG_CONFIG)"; fi; \
	if [ -n "$(PKG_CONFIG_PATH)" ]; then export PKG_CONFIG_PATH="$(PKG_CONFIG_PATH)"; fi; \
	PATH="$$path" swift build -c release
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
