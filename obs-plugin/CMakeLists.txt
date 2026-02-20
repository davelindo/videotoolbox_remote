cmake_minimum_required(VERSION 3.16)

project(obs-vtremoted VERSION 1.0.0)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)

# OBS paths - can be set via environment or cmake args
# OBS_SOURCE_DIR: path to obs-studio source (contains libobs/)
# OBS_BUILD_DIR: path to obs-studio build directory (contains libobs.so/dylib)
set(OBS_SOURCE_DIR "$ENV{OBS_SOURCE_DIR}" CACHE PATH "OBS Studio source directory")
set(OBS_BUILD_DIR "$ENV{OBS_BUILD_DIR}" CACHE PATH "OBS Studio build directory")

# Try to find OBS via package first
find_package(libobs QUIET)

if(NOT libobs_FOUND)
    # Fall back to manual path configuration
    if(NOT OBS_SOURCE_DIR OR NOT EXISTS "${OBS_SOURCE_DIR}/libobs")
        # Try common paths
        if(EXISTS "$ENV{HOME}/git/obs-studio/libobs")
            set(OBS_SOURCE_DIR "$ENV{HOME}/git/obs-studio")
        else()
            message(FATAL_ERROR 
                "Could not find OBS Studio. Please set OBS_SOURCE_DIR:\n"
                "  cmake -DOBS_SOURCE_DIR=/path/to/obs-studio ..\n"
                "or set OBS_SOURCE_DIR environment variable.")
        endif()
    endif()
    
    message(STATUS "Using OBS source from: ${OBS_SOURCE_DIR}")
    
    # Set up include paths
    set(OBS_INCLUDE_DIRS
        ${CMAKE_CURRENT_SOURCE_DIR}/include  # For obsconfig.h stub
        ${OBS_SOURCE_DIR}/libobs
        ${OBS_SOURCE_DIR}/deps/media-playback
    )
    
    # Find SIMDE (required by OBS headers)
    find_path(SIMDE_INCLUDE_DIR simde/x86/sse2.h
        HINTS /opt/homebrew/opt/simde/include /usr/local/include /usr/include
    )
    if(SIMDE_INCLUDE_DIR)
        list(APPEND OBS_INCLUDE_DIRS ${SIMDE_INCLUDE_DIR})
        message(STATUS "Found SIMDE: ${SIMDE_INCLUDE_DIR}")
    else()
        message(FATAL_ERROR "SIMDE not found. Install via: brew install simde")
    endif()
endif()

# Find LZ4
find_package(PkgConfig REQUIRED)
pkg_check_modules(LZ4 REQUIRED liblz4)

# Plugin sources
set(PLUGIN_SOURCES
    src/plugin-main.c
    src/vtremoted-encoder.c
    src/vtremoted-client.cpp
)

# Create the plugin
add_library(obs-vtremoted MODULE ${PLUGIN_SOURCES})

target_include_directories(obs-vtremoted PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${LZ4_INCLUDE_DIRS}
)

if(libobs_FOUND)
    target_link_libraries(obs-vtremoted PRIVATE
        OBS::libobs
        ${LZ4_LIBRARIES}
    )
else()
    # Header-only mode: include OBS headers, no linking (plugin loaded by OBS)
    target_include_directories(obs-vtremoted PRIVATE ${OBS_INCLUDE_DIRS})
    target_link_directories(obs-vtremoted PRIVATE ${LZ4_LIBRARY_DIRS})
    target_link_libraries(obs-vtremoted PRIVATE ${LZ4_LIBRARIES})
    
    # We need to link against libobs if we have a build dir
    if(OBS_BUILD_DIR AND EXISTS "${OBS_BUILD_DIR}")
        find_library(LIBOBS_LIBRARY 
            NAMES obs libobs
            PATHS ${OBS_BUILD_DIR}/libobs ${OBS_BUILD_DIR}
            NO_DEFAULT_PATH
        )
        if(LIBOBS_LIBRARY)
            target_link_libraries(obs-vtremoted PRIVATE ${LIBOBS_LIBRARY})
            message(STATUS "Found libobs: ${LIBOBS_LIBRARY}")
        endif()
    endif()
endif()

# Platform-specific settings
# Platform-specific settings
if(APPLE)
    set_target_properties(obs-vtremoted PROPERTIES
        BUNDLE TRUE
        MACOSX_BUNDLE_BUNDLE_NAME "obs-vtremoted"
        MACOSX_BUNDLE_GUI_IDENTIFIER "com.davelindon.obs-vtremoted"
        BUNDLE_EXTENSION "plugin"
        OUTPUT_NAME "obs-vtremoted"
    )
    # On macOS, OBS plugins don't need to link libobs directly
    # They get symbols resolved at load time
    set_target_properties(obs-vtremoted PROPERTIES
        LINK_FLAGS "-undefined dynamic_lookup"
    )
elseif(WIN32)
    target_link_libraries(obs-vtremoted PRIVATE ws2_32)
endif()

# Installation
if(APPLE)
    set(OBS_PLUGIN_DIR "$ENV{HOME}/Library/Application Support/obs-studio/plugins")
    
    # Install the bundle
    install(TARGETS obs-vtremoted
        BUNDLE DESTINATION "${OBS_PLUGIN_DIR}"
        LIBRARY DESTINATION "${OBS_PLUGIN_DIR}"
    )
    
    # Install data to Resources inside the bundle
    # Note: CMake automatically puts resources in Contents/Resources for bundles if identified
    # But here we manually move data.
    # Actually, proper way is to add data files to target sources with RESOURCE property?
    # Or just install explicit directory into bundle?
    # Simpler: Install data contents to Contents/Resources/
    install(DIRECTORY data/
        DESTINATION "${OBS_PLUGIN_DIR}/obs-vtremoted.plugin/Contents/Resources"
    )
elseif(WIN32)
    set(OBS_PLUGIN_DIR "$ENV{APPDATA}/obs-studio/plugins")
    install(TARGETS obs-vtremoted
        LIBRARY DESTINATION "${OBS_PLUGIN_DIR}/obs-vtremoted/bin"
    )
    install(DIRECTORY data/
        DESTINATION "${OBS_PLUGIN_DIR}/obs-vtremoted/data"
    )
else()
    set(OBS_PLUGIN_DIR "$ENV{HOME}/.config/obs-studio/plugins")
    install(TARGETS obs-vtremoted
        LIBRARY DESTINATION "${OBS_PLUGIN_DIR}/obs-vtremoted/bin"
    )
    install(DIRECTORY data/
        DESTINATION "${OBS_PLUGIN_DIR}/obs-vtremoted/data"
    )
endif()

message(STATUS "obs-vtremoted will be installed to: ${OBS_PLUGIN_DIR}")
