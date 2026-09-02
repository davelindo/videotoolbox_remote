BUILD_DIR ?= build
BUILD_TYPE ?= Release
PREFIX ?= /opt/vtremote-vaapi

.PHONY: all configure test install clean package package-source release

all: configure
	cmake --build $(BUILD_DIR) --parallel

configure:
	cmake -S . -B $(BUILD_DIR) -DCMAKE_BUILD_TYPE=$(BUILD_TYPE) \
		-DVTREMOTE_VERSION="$${VERSION:-dev}"

test: all
	cd $(BUILD_DIR) && ctest --output-on-failure

install: test
	cmake --install $(BUILD_DIR) --prefix $(PREFIX)

clean:
	cmake -E remove_directory $(BUILD_DIR)

package: test
	./scripts/package.sh

package-source:
	./scripts/package-source.sh

release: package package-source
