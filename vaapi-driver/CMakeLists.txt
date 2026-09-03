cmake_minimum_required(VERSION 3.16)
project(vtremote_vaapi LANGUAGES C)

include(GNUInstallDirs)
include(CTest)
find_package(Threads REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBVA REQUIRED libva>=1.22)
pkg_check_modules(LZ4 REQUIRED IMPORTED_TARGET liblz4)
pkg_check_modules(ZSTD REQUIRED IMPORTED_TARGET libzstd)

set(VTREMOTE_VERSION "dev" CACHE STRING "Repository release/build version")
option(VTREMOTE_INSTALL_VGEM_ALIAS
    "Install vgem_drv_video.so symlink for automatic vgem discovery" ON)
option(VTREMOTE_INSTALL_IHD_ALIAS
    "Install isolated iHD_drv_video.so compatibility symlink" OFF)
option(VTREMOTE_WARNINGS_AS_ERRORS "Treat driver warnings as build errors" OFF)
option(VTREMOTE_ENABLE_STOCK_FFMPEG_TEST "Run stock FFmpeg VA-API E2E tests" ON)
set(VTREMOTE_PLEX_FFMPEG_SOURCE_DIR "" CACHE PATH
    "Configured FFmpeg 6.1 source tree used to build the Plex BSF shim")

set(VTREMOTE_WARNING_FLAGS -Wall -Wextra -Wpedantic)
if(VTREMOTE_WARNINGS_AS_ERRORS)
    list(APPEND VTREMOTE_WARNING_FLAGS -Werror)
endif()

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

add_library(vtremote_client STATIC
    src/protocol.c
    src/client.c
)
target_include_directories(vtremote_client PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>
)
target_link_libraries(vtremote_client PUBLIC PkgConfig::LZ4 PkgConfig::ZSTD)
set_target_properties(vtremote_client PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    C_VISIBILITY_PRESET hidden
)
target_compile_definitions(vtremote_client PUBLIC
    VTREMOTE_VERSION="${VTREMOTE_VERSION}"
)
target_compile_options(vtremote_client PRIVATE ${VTREMOTE_WARNING_FLAGS})

add_executable(vtremote-probe tools/vtremote-probe.c)
target_link_libraries(vtremote-probe PRIVATE vtremote_client)
target_compile_options(vtremote-probe PRIVATE ${VTREMOTE_WARNING_FLAGS})

add_executable(vtremote-plex-transcoder tools/plex-transcoder-wrapper.c)
target_link_libraries(vtremote-plex-transcoder PRIVATE ${CMAKE_DL_LIBS})
target_compile_options(vtremote-plex-transcoder PRIVATE ${VTREMOTE_WARNING_FLAGS})

if(VTREMOTE_PLEX_FFMPEG_SOURCE_DIR)
    if(NOT EXISTS "${VTREMOTE_PLEX_FFMPEG_SOURCE_DIR}/libavutil/avconfig.h")
        message(FATAL_ERROR
            "VTREMOTE_PLEX_FFMPEG_SOURCE_DIR must be an FFmpeg 6.1 tree after configure")
    endif()
    add_library(vtremote_plex_bsf SHARED
        tools/plex-vtremote-bsf.c
        ${CMAKE_CURRENT_SOURCE_DIR}/../ffmpeg/libavcodec/bsf/vtremote_transcode.c
        ${CMAKE_CURRENT_SOURCE_DIR}/../ffmpeg/libavcodec/vtremote_proto.c
    )
    target_include_directories(vtremote_plex_bsf SYSTEM PRIVATE
        ${VTREMOTE_PLEX_FFMPEG_SOURCE_DIR}
        ${VTREMOTE_PLEX_FFMPEG_SOURCE_DIR}/libavcodec
    )
    target_link_libraries(vtremote_plex_bsf PRIVATE
        ${CMAKE_DL_LIBS}
        Threads::Threads
    )
    target_compile_definitions(vtremote_plex_bsf PRIVATE _POSIX_C_SOURCE=200809L)
    target_compile_options(vtremote_plex_bsf PRIVATE
        ${VTREMOTE_WARNING_FLAGS}
        -Wno-missing-field-initializers
    )
    set_target_properties(vtremote_plex_bsf PROPERTIES
        C_VISIBILITY_PRESET hidden
        PREFIX ""
        OUTPUT_NAME "vtremote-plex-bsf"
    )
endif()

add_library(vtremote_drv_video MODULE src/va_driver.c)
target_include_directories(vtremote_drv_video PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)
target_include_directories(vtremote_drv_video SYSTEM PRIVATE
    ${LIBVA_INCLUDE_DIRS}
)
target_link_libraries(vtremote_drv_video PRIVATE
    vtremote_client
    Threads::Threads
)
target_compile_options(vtremote_drv_video PRIVATE ${VTREMOTE_WARNING_FLAGS})
set_target_properties(vtremote_drv_video PROPERTIES
    C_VISIBILITY_PRESET hidden
    PREFIX ""
    OUTPUT_NAME "vtremote_drv_video"
)
if(UNIX AND NOT APPLE)
    add_custom_command(TARGET vtremote_drv_video POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E remove -f
            $<TARGET_FILE_DIR:vtremote_drv_video>/vgem_drv_video.so
        COMMAND ${CMAKE_COMMAND} -E create_symlink
            $<TARGET_FILE_NAME:vtremote_drv_video>
            $<TARGET_FILE_DIR:vtremote_drv_video>/vgem_drv_video.so
        VERBATIM
    )
endif()

install(TARGETS vtremote_drv_video
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}/dri
)
if(VTREMOTE_INSTALL_VGEM_ALIAS)
    install(CODE "
        set(alias \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_LIBDIR}/dri/vgem_drv_video.so\")
        if(IS_SYMLINK \"\${alias}\")
            file(READ_SYMLINK \"\${alias}\" target)
            if(NOT target STREQUAL \"vtremote_drv_video.so\")
                message(FATAL_ERROR \"refusing to replace \${alias} -> \${target}\")
            endif()
        elseif(EXISTS \"\${alias}\")
            message(FATAL_ERROR \"refusing to replace existing \${alias}\")
        else()
            file(CREATE_LINK vtremote_drv_video.so \"\${alias}\" SYMBOLIC)
        endif()
    ")
endif()
if(VTREMOTE_INSTALL_IHD_ALIAS)
    install(CODE "
        set(alias \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_LIBDIR}/dri/iHD_drv_video.so\")
        if(IS_SYMLINK \"\${alias}\")
            file(READ_SYMLINK \"\${alias}\" target)
            if(NOT target STREQUAL \"vtremote_drv_video.so\")
                message(FATAL_ERROR \"refusing to replace \${alias} -> \${target}\")
            endif()
        elseif(EXISTS \"\${alias}\")
            message(FATAL_ERROR \"refusing to replace existing \${alias}\")
        else()
            file(CREATE_LINK vtremote_drv_video.so \"\${alias}\" SYMBOLIC)
        endif()
    ")
endif()
install(TARGETS vtremote_client
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
)
install(TARGETS vtremote-probe
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)
install(TARGETS vtremote-plex-transcoder
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)
if(TARGET vtremote_plex_bsf)
    install(TARGETS vtremote_plex_bsf
        LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    )
endif()
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
configure_file(cmake/vtremote-client.pc.in vtremote-client.pc @ONLY)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/vtremote-client.pc
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/pkgconfig)

if(BUILD_TESTING)
    add_executable(vtremote_driver_test tests/test_driver.c)
    target_include_directories(vtremote_driver_test SYSTEM PRIVATE ${LIBVA_INCLUDE_DIRS})
    target_link_libraries(vtremote_driver_test PRIVATE
        ${CMAKE_DL_LIBS}
    )
    target_compile_options(vtremote_driver_test PRIVATE ${VTREMOTE_WARNING_FLAGS})

    add_executable(vtremote_protocol_test tests/test_protocol.c)
    target_link_libraries(vtremote_protocol_test PRIVATE vtremote_client)
    target_compile_options(vtremote_protocol_test PRIVATE ${VTREMOTE_WARNING_FLAGS})
    add_test(NAME vtremote_protocol_unit COMMAND vtremote_protocol_test)

    add_executable(vtremote_client_reconnect_test tests/test_client_reconnect.c)
    target_link_libraries(vtremote_client_reconnect_test PRIVATE vtremote_client)
    target_compile_options(vtremote_client_reconnect_test PRIVATE ${VTREMOTE_WARNING_FLAGS})

    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    add_test(NAME vtremote_client_reconnect_e2e
        COMMAND ${Python3_EXECUTABLE}
            ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_client_reconnect_e2e.py
            --test $<TARGET_FILE:vtremote_client_reconnect_test>
            --mock ${CMAKE_CURRENT_SOURCE_DIR}/../tests/integration/mock_vtremoted/mock_vtremoted.py
    )
    add_test(NAME vtremote_plex_transcoder_wrapper_unit
        COMMAND ${Python3_EXECUTABLE}
            ${CMAKE_CURRENT_SOURCE_DIR}/tests/test_plex_transcoder_wrapper.py
            --wrapper $<TARGET_FILE:vtremote-plex-transcoder>
    )

    add_executable(vtremote_plex_ffmpeg_compat_test
        tests/test_plex_ffmpeg_compat.c)
    target_include_directories(vtremote_plex_ffmpeg_compat_test PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/tools)
    target_compile_options(vtremote_plex_ffmpeg_compat_test PRIVATE
        ${VTREMOTE_WARNING_FLAGS})
    add_test(NAME vtremote_plex_ffmpeg_compat_unit
        COMMAND vtremote_plex_ffmpeg_compat_test)

    set(VTREMOTE_MOCK_PATH
        "${CMAKE_CURRENT_SOURCE_DIR}/../tests/integration/mock_vtremoted/mock_vtremoted.py"
        CACHE FILEPATH "Path to the repository mock vtremoted")
    if(EXISTS "${VTREMOTE_MOCK_PATH}")
        foreach(codec h264 hevc hevc10)
            add_test(NAME vtremote_driver_${codec}_e2e
                COMMAND ${Python3_EXECUTABLE}
                    ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_e2e.py
                    --driver $<TARGET_FILE:vtremote_drv_video>
                    --test $<TARGET_FILE:vtremote_driver_test>
                    --mock ${VTREMOTE_MOCK_PATH}
                    --codec ${codec}
            )
        endforeach()
        add_test(NAME vtremote_probe_e2e
            COMMAND ${Python3_EXECUTABLE}
                ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_probe_e2e.py
                --probe $<TARGET_FILE:vtremote-probe>
                --mock ${VTREMOTE_MOCK_PATH}
        )
    else()
        message(STATUS "Repository mock unavailable; skipping client/driver E2E tests")
    endif()

    if(UNIX AND NOT APPLE AND VTREMOTE_ENABLE_STOCK_FFMPEG_TEST)
        add_library(fake_drm_rendernode MODULE tests/fake_drm_rendernode.c)
        target_compile_options(fake_drm_rendernode PRIVATE ${VTREMOTE_WARNING_FLAGS})
        set_target_properties(fake_drm_rendernode PROPERTIES
            PREFIX ""
            OUTPUT_NAME "fake_drm_rendernode"
        )
        find_program(FFMPEG_EXECUTABLE ffmpeg)
        if(FFMPEG_EXECUTABLE AND EXISTS "${VTREMOTE_MOCK_PATH}")
            execute_process(
                COMMAND ${FFMPEG_EXECUTABLE} -hide_banner -encoders
                OUTPUT_VARIABLE FFMPEG_ENCODERS
                ERROR_QUIET
            )
            if(FFMPEG_ENCODERS MATCHES "h264_vaapi" AND
               FFMPEG_ENCODERS MATCHES "hevc_vaapi")
                add_test(NAME vtremote_stock_ffmpeg_e2e
                    COMMAND ${Python3_EXECUTABLE}
                        ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_ffmpeg_e2e.py
                        --ffmpeg ${FFMPEG_EXECUTABLE}
                        --driver $<TARGET_FILE:vtremote_drv_video>
                        --interposer $<TARGET_FILE:fake_drm_rendernode>
                        --mock ${VTREMOTE_MOCK_PATH}
                )
            else()
                message(STATUS "Skipping stock FFmpeg E2E: VAAPI encoders unavailable")
            endif()
        endif()
    endif()
endif()
