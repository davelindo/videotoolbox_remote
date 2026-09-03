UNAME_S := $(shell uname -s)
IS_DARWIN := $(filter Darwin,$(UNAME_S))

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

FFMPEG_DIR := ffmpeg
VTREMOTED_DIR := vtremoted
VAAPI_DRIVER_DIR := vaapi-driver
VTREMOTE_VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null | sed 's/^v//' || echo dev)

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
# Keep release artifacts runnable on older supported macOS versions even when
# building on macOS 27+ or with a future SDK.
MACOSX_DEPLOYMENT_TARGET ?= 13.0
ifneq ($(wildcard /opt/homebrew/bin/pkg-config),)
PKG_CONFIG ?= /opt/homebrew/bin/pkg-config
PKG_CONFIG_PATH ?= /opt/homebrew/lib/pkgconfig:/opt/homebrew/share/pkgconfig
else
ifneq ($(wildcard /usr/local/bin/pkg-config),)
PKG_CONFIG ?= /usr/local/bin/pkg-config
PKG_CONFIG_PATH ?= /usr/local/lib/pkgconfig:/usr/local/share/pkgconfig
endif
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

FFMPEG_CONFIGURE_FLAGS_BASE ?= --enable-gpl --enable-liblz4 --enable-libzstd --enable-libvmaf --enable-libaom --enable-libdav1d --enable-libsvtav1 --enable-libopus --enable-libvorbis --enable-libmp3lame --enable-libx264 --enable-libx265 --enable-libvpx --enable-videotoolbox-remote --disable-debug --disable-response-files
FFMPEG_DISABLE_X86ASM ?=

ifeq ($(IS_DARWIN),Darwin)
FFMPEG_CONFIGURE_FLAGS ?= --enable-videotoolbox $(FFMPEG_CONFIGURE_FLAGS_BASE)
else
FFMPEG_CONFIGURE_FLAGS ?= $(FFMPEG_CONFIGURE_FLAGS_BASE)
endif
JOBS ?= $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 2)

VTREMOTED_LISTEN ?= 127.0.0.1:5555
VTREMOTED_LOG_LEVEL ?= 1
VTREMOTED_TOKEN ?=
VTREMOTED_SYSTEM ?=
VTREMOTED_LABEL ?= com.davelindon.vtremoted
GITHUB_REPO ?= davelindo/videotoolbox_remote

# SwiftPM uses macOS sandboxing by default (sandbox-exec). In sandboxed environments (e.g. some CI runners
# and Codex), sandbox-exec can fail with "Operation not permitted". Allow overriding to re-enable.
SWIFT_BUILD_SANDBOX_FLAGS ?= --disable-sandbox

.PHONY: build build-ffmpeg build-vtremoted build-vaapi-driver test-vaapi-driver package-vaapi-driver install install-ffmpeg install-vtremoted install-vaapi-driver install-vtremoted-restart verify-vtremoted-install clean clean-ffmpeg clean-vtremoted clean-vaapi-driver test-obs-plugin test-obs-plugin-integration sync-github-metadata release-notes release-notes-all
.SILENT: build-ffmpeg

build: build-ffmpeg build-vtremoted $(if $(IS_DARWIN),,build-vaapi-driver)

build-ffmpeg:
	cd $(FFMPEG_DIR) && \
	config_flags="$(FFMPEG_CONFIGURE_FLAGS)"; \
	if [ "$(FFMPEG_DISABLE_X86ASM)" = "1" ] && ! printf "%s" "$$config_flags" | grep -qE '(^|[[:space:]])--disable-x86asm([[:space:]]|$$)'; then \
		config_flags="$$config_flags --disable-x86asm"; \
	fi; \
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
		if ! printf "%s" "$$config_flags" | grep -qE '(^|[[:space:]])--(enable|disable)-videotoolbox([[:space:]]|$$)'; then \
			config_flags="$$config_flags --enable-videotoolbox"; \
		fi; \
		if [ -n "$$sdkroot" ] && ! printf "%s" "$$config_flags" | grep -q -- "--sysroot="; then \
			config_flags="$$config_flags --sysroot=$$sdkroot"; \
		fi; \
		sysroot_flag="-isysroot$$sdkroot"; \
		framework_flag="-F$$sdkroot/System/Library/Frameworks"; \
		pkg_config="$(PKG_CONFIG)"; \
		if [ -n "$$pkg_config" ] && [ -x "$$pkg_config" ] && ! printf "%s" "$$config_flags" | grep -q -- "--pkg-config="; then \
			config_flags="$$config_flags --pkg-config=$$pkg_config"; \
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
			brew_prefix=""; \
			if [ -d /opt/homebrew ]; then \
				brew_prefix="/opt/homebrew"; \
			elif [ -d /usr/local ]; then \
				brew_prefix="/usr/local"; \
			fi; \
			if [ -n "$$brew_prefix" ]; then \
				inc="$$brew_prefix/include"; \
				lib="$$brew_prefix/lib"; \
				if [ -d "$$inc" ]; then \
					if ! printf "%s" "$$cppflags" | grep -q -- "-I$$inc"; then cppflags="-I$$inc $$cppflags"; fi; \
					if ! printf "%s" "$$cflags" | grep -q -- "-I$$inc"; then cflags="-I$$inc $$cflags"; fi; \
					if ! printf "%s" "$$objcflags" | grep -q -- "-I$$inc"; then objcflags="-I$$inc $$objcflags"; fi; \
				fi; \
				if [ -d "$$lib" ]; then \
					if ! printf "%s" "$$ldflags" | grep -q -- "-L$$lib"; then ldflags="-L$$lib $$ldflags"; fi; \
				fi; \
			fi; \
		fi; \
		need_config=0; \
		need_reason=""; \
		if [ ! -f ffbuild/config.mak ]; then \
			need_config=1; \
			need_reason="missing ffbuild/config.mak"; \
		else \
			current=$$(sed -n 's/^FFMPEG_CONFIGURATION=//p' ffbuild/config.mak); \
			if [ "$$current" != "$$config_flags" ]; then \
				need_config=1; \
				need_reason="FFMPEG_CONFIGURATION mismatch"; \
			fi; \
		fi; \
		if [ "$$need_config" = "0" ] && [ ffbuild/config.mak -ot configure ]; then \
			need_config=1; \
			need_reason="configure script newer than ffbuild/config.mak"; \
		fi; \
		if [ "$$need_config" = "0" ] && [ ! -f ffbuild/config_components.h ]; then \
			need_config=1; \
			need_reason="missing ffbuild/config_components.h"; \
		fi; \
		if [ "$$need_config" = "0" ] && [ ffbuild/config_components.h -ot libavformat/protocols.c ]; then \
			need_config=1; \
			need_reason="stale component config for protocols"; \
		fi; \
		if [ "$$need_config" = "0" ] && [ ffbuild/config_components.h -ot libavfilter/allfilters.c ]; then \
			need_config=1; \
			need_reason="stale component config for filters"; \
		fi; \
		if [ "$$need_config" = "1" ]; then \
			echo "Reconfiguring ffmpeg ($$need_reason)"; \
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
	export MACOSX_DEPLOYMENT_TARGET="$(MACOSX_DEPLOYMENT_TARGET)"; \
	if [ -n "$(PKG_CONFIG)" ]; then export PKG_CONFIG="$(PKG_CONFIG)"; fi; \
	if [ -n "$(PKG_CONFIG_PATH)" ]; then export PKG_CONFIG_PATH="$(PKG_CONFIG_PATH)"; fi; \
	PATH="$$path" swift build -c release $(SWIFT_BUILD_SANDBOX_FLAGS)
else
	@echo "Skipping vtremoted build (not macOS)"
endif

build-vaapi-driver:
ifeq ($(IS_DARWIN),Darwin)
	@echo "The VA-API driver release target is Linux-only" >&2
	@exit 1
else
	@cmake -S $(VAAPI_DRIVER_DIR) -B $(VAAPI_DRIVER_DIR)/build \
		-DCMAKE_BUILD_TYPE=Release -DVTREMOTE_VERSION="$(VTREMOTE_VERSION)" \
		-DVTREMOTE_WARNINGS_AS_ERRORS=ON
	@cmake --build $(VAAPI_DRIVER_DIR)/build --parallel $(JOBS)
endif

test-vaapi-driver: build-vaapi-driver
	@cd $(VAAPI_DRIVER_DIR)/build && ctest --output-on-failure

package-vaapi-driver:
ifeq ($(IS_DARWIN),Darwin)
	@echo "The VA-API driver release target is Linux x86_64-only" >&2
	@exit 1
else
	@VERSION="$(VTREMOTE_VERSION)" \
		VTREMOTE_PLEX_FFMPEG_SOURCE_DIR="$(VTREMOTE_PLEX_FFMPEG_SOURCE_DIR)" \
		$(VAAPI_DRIVER_DIR)/scripts/package.sh
endif

install: install-ffmpeg install-vtremoted $(if $(IS_DARWIN),,install-vaapi-driver)

install-ffmpeg:
	@install -d "$(BINDIR)"
	@install -m 0755 "$(FFMPEG_DIR)/ffmpeg" "$(BINDIR)/ffmpeg"

install-vtremoted:
ifeq ($(IS_DARWIN),Darwin)
	@install -d "$(BINDIR)"
	@install -m 0755 "$(VTREMOTED_DIR)/.build/release/vtremoted" "$(BINDIR)/vtremoted"
	@args="--label $(VTREMOTED_LABEL) --bin $(BINDIR)/vtremoted --listen $(VTREMOTED_LISTEN) --log-level $(VTREMOTED_LOG_LEVEL)"; \
	if [ -n "$(VTREMOTED_TOKEN)" ]; then args="$$args --token $(VTREMOTED_TOKEN)"; fi; \
	if [ -n "$(VTREMOTED_SYSTEM)" ]; then args="$$args --system"; fi; \
	"$(VTREMOTED_DIR)/install_launchd.sh" $$args
else
	@echo "Skipping vtremoted install (not macOS)"
endif

install-vaapi-driver: test-vaapi-driver
	@cmake --install $(VAAPI_DRIVER_DIR)/build --prefix /opt/vtremote-vaapi

install-vtremoted-restart: build-vtremoted install-vtremoted verify-vtremoted-install

verify-vtremoted-install:
ifeq ($(IS_DARWIN),Darwin)
	@domain="gui/$$(id -u)"; \
	if [ -n "$(VTREMOTED_SYSTEM)" ] || [ "$$(id -u)" = "0" ]; then domain="system"; fi; \
	port="$(VTREMOTED_LISTEN)"; port="$${port##*:}"; \
	echo "launchd service: $$domain/$(VTREMOTED_LABEL)"; \
	launchctl print "$$domain/$(VTREMOTED_LABEL)" 2>/dev/null | sed -n '/program =/p;/arguments =/,/}/p;/pid =/p;/last exit/p' || true; \
	echo "listening sockets:"; \
	lsof -nP -iTCP:$$port -sTCP:LISTEN 2>/dev/null || true; \
	echo "processes:"; \
	pgrep -fl vtremoted || true; \
	if [ -x "$(BINDIR)/vtremoted" ]; then \
		shasum -a 256 "$(VTREMOTED_DIR)/.build/release/vtremoted" "$(BINDIR)/vtremoted"; \
	fi
else
	@echo "Skipping vtremoted verification (not macOS)"
endif

clean: clean-ffmpeg clean-vtremoted clean-vaapi-driver

clean-ffmpeg:
	@$(MAKE) -C $(FFMPEG_DIR) clean || true

clean-vtremoted:
ifeq ($(IS_DARWIN),Darwin)
	@cd $(VTREMOTED_DIR) && swift package clean $(SWIFT_BUILD_SANDBOX_FLAGS)
else
	@echo "Skipping vtremoted clean (not macOS)"
endif

clean-vaapi-driver:
	@cmake -E remove_directory $(VAAPI_DRIVER_DIR)/build

test-obs-plugin:
	@bash tests/integration/run_obs_plugin_client_mock.sh
	@bash tests/integration/run_obs_plugin_integration.sh

test-obs-plugin-integration:
	@bash tests/integration/run_obs_plugin_integration.sh

sync-github-metadata:
	@bash scripts/sync_github_metadata.sh "$(GITHUB_REPO)"

release-notes:
	@if [ -z "$(TAG)" ]; then \
		echo "Usage: make release-notes TAG=vX.Y.Z [GITHUB_REPO=owner/repo]" >&2; \
		exit 1; \
	fi
	@bash scripts/apply_release_notes.sh "$(TAG)" "$(GITHUB_REPO)"

release-notes-all:
	@bash scripts/apply_release_notes.sh --all "$(GITHUB_REPO)"
