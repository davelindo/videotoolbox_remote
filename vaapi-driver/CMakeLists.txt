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

    set(VTREMOTE_MOCK_PATH
        "${CMAKE_CURRENT_SOURCE_DIR}/../tests/integration/mock_vtremoted/mock_vtremoted.py"
        CACHE FILEPATH "Path to the repository mock vtremoted")
    if(EXISTS "${VTREMOTE_MOCK_PATH}")
        find_package(Python3 REQUIRED COMPONENTS Interpreter)
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
