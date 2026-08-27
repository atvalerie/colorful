cmake_minimum_required(VERSION 3.25)

set(COLORFUL_VERSION_FILE "${CMAKE_CURRENT_SOURCE_DIR}/../../VERSION")
file(STRINGS "${COLORFUL_VERSION_FILE}" COLORFUL_APP_VERSION LIMIT_COUNT 1)
if(NOT COLORFUL_APP_VERSION MATCHES "^[0-9]+\\.[0-9]+\\.[0-9]+$")
    message(FATAL_ERROR "VERSION must contain a three-part numeric version such as 0.2.0")
endif()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${COLORFUL_VERSION_FILE}")

project(colorfulDesktop VERSION "${COLORFUL_APP_VERSION}" LANGUAGES CXX)
include(CTest)
if(WIN32)
    enable_language(RC)
endif()

execute_process(
    COMMAND git rev-parse --short=12 HEAD
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../.."
    OUTPUT_VARIABLE COLORFUL_GIT_COMMIT
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
)
if(NOT COLORFUL_GIT_COMMIT)
    set(COLORFUL_GIT_COMMIT "unknown")
endif()
execute_process(
    COMMAND git rev-parse HEAD
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../.."
    OUTPUT_VARIABLE COLORFUL_GIT_COMMIT_FULL
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
)
if(NOT COLORFUL_GIT_COMMIT_FULL)
    set(COLORFUL_GIT_COMMIT_FULL "unknown")
endif()
execute_process(
    COMMAND git describe --tags --exact-match --match "v[0-9]*" --dirty=-dirty
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../.."
    OUTPUT_VARIABLE COLORFUL_GIT_TAG
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
)
string(TIMESTAMP COLORFUL_BUILD_DATE "%Y-%m-%d %H:%M:%S UTC" UTC)

set(COLORFUL_BUILD_CHANNEL "$ENV{COLORFUL_BUILD_CHANNEL}")
if(NOT COLORFUL_BUILD_CHANNEL)
    set(COLORFUL_BUILD_CHANNEL "release")
endif()
if(NOT COLORFUL_BUILD_CHANNEL MATCHES "^(release|dev)$")
    message(FATAL_ERROR "COLORFUL_BUILD_CHANNEL must be release or dev")
endif()
set(COLORFUL_BUILD_NUMBER "$ENV{COLORFUL_BUILD_NUMBER}")
if(COLORFUL_BUILD_CHANNEL STREQUAL "dev")
    if(NOT COLORFUL_BUILD_NUMBER)
        set(COLORFUL_BUILD_NUMBER "local")
    endif()
    set(COLORFUL_DISPLAY_VERSION
        "${PROJECT_VERSION}-dev.${COLORFUL_BUILD_NUMBER}+${COLORFUL_GIT_COMMIT}")
else()
    set(COLORFUL_DISPLAY_VERSION "${PROJECT_VERSION}")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui Quick QuickControls2 Network)
if(UNIX AND NOT APPLE)
    find_package(Qt6 6.8 REQUIRED COMPONENTS DBus)
endif()

# Discord's Social SDK is the supported integration surface for native party
# invites and Ask to Join. Keep the dependency in-tree so Windows and AppImage
# releases are built from the same pinned SDK rather than a developer's local
# installation.
set(COLORFUL_DISCORD_SDK_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/discord_social_sdk")
set(COLORFUL_DISCORD_SDK_INCLUDE "${COLORFUL_DISCORD_SDK_ROOT}/include")
if(WIN32)
    set(COLORFUL_DISCORD_SDK_LIBRARY "${COLORFUL_DISCORD_SDK_ROOT}/lib/release/discord_partner_sdk.lib")
    set(COLORFUL_DISCORD_SDK_RUNTIME "${COLORFUL_DISCORD_SDK_ROOT}/bin/release/discord_partner_sdk.dll")
else()
    set(COLORFUL_DISCORD_SDK_LIBRARY "${COLORFUL_DISCORD_SDK_ROOT}/lib/release/libdiscord_partner_sdk.so")
    set(COLORFUL_DISCORD_SDK_RUNTIME "${COLORFUL_DISCORD_SDK_LIBRARY}")
endif()
foreach(COLORFUL_DISCORD_SDK_FILE IN ITEMS
        "${COLORFUL_DISCORD_SDK_INCLUDE}/discordpp.h"
        "${COLORFUL_DISCORD_SDK_INCLUDE}/cdiscord.h"
        "${COLORFUL_DISCORD_SDK_LIBRARY}"
        "${COLORFUL_DISCORD_SDK_RUNTIME}")
    if(NOT EXISTS "${COLORFUL_DISCORD_SDK_FILE}")
        message(FATAL_ERROR "Pinned Discord Social SDK file is missing: ${COLORFUL_DISCORD_SDK_FILE}")
    endif()
endforeach()
add_library(colorful-discord-social SHARED IMPORTED GLOBAL)
set_target_properties(colorful-discord-social PROPERTIES
    IMPORTED_LOCATION "${COLORFUL_DISCORD_SDK_RUNTIME}"
    INTERFACE_INCLUDE_DIRECTORIES "${COLORFUL_DISCORD_SDK_INCLUDE}")
if(WIN32)
    set_target_properties(colorful-discord-social PROPERTIES
        IMPORTED_IMPLIB "${COLORFUL_DISCORD_SDK_LIBRARY}")
endif()

set(COLORFUL_MPV_MODE "compatibility" CACHE STRING
    "libmpv validation mode: compatibility or official")
set_property(CACHE COLORFUL_MPV_MODE PROPERTY STRINGS compatibility official)
set(COLORFUL_EXPECTED_MPV_VERSION "" CACHE STRING
    "Exact libmpv version required for official builds")
if(NOT COLORFUL_MPV_MODE MATCHES "^(compatibility|official)$")
    message(FATAL_ERROR "COLORFUL_MPV_MODE must be compatibility or official")
endif()
if(COLORFUL_MPV_MODE STREQUAL "official" AND NOT COLORFUL_EXPECTED_MPV_VERSION)
    message(FATAL_ERROR "Official builds must set COLORFUL_EXPECTED_MPV_VERSION")
endif()

if(WIN32)
    set(COLORFUL_MPV_ROOT "" CACHE PATH "Root of a Windows libmpv development package")
    set(COLORFUL_MPV_VERSION "unverified-windows-sdk" CACHE STRING
        "Version identity of the Windows libmpv development package")
    find_path(MPV_INCLUDE_DIR mpv/client.h
        HINTS "${COLORFUL_MPV_ROOT}/include")
    find_library(MPV_LIBRARY NAMES mpv libmpv mpv-2
        HINTS "${COLORFUL_MPV_ROOT}" "${COLORFUL_MPV_ROOT}/lib")
    find_file(MPV_RUNTIME NAMES mpv-2.dll libmpv-2.dll mpv.dll
        HINTS "${COLORFUL_MPV_ROOT}" "${COLORFUL_MPV_ROOT}/bin")
    if(NOT MPV_INCLUDE_DIR OR NOT MPV_LIBRARY OR NOT MPV_RUNTIME)
        message(FATAL_ERROR "A Windows libmpv SDK is required. Set COLORFUL_MPV_ROOT to a directory containing include/mpv/client.h, an import library, and mpv-2.dll.")
    endif()
    add_library(colorful-mpv UNKNOWN IMPORTED GLOBAL)
    set_target_properties(colorful-mpv PROPERTIES
        IMPORTED_LOCATION "${MPV_LIBRARY}"
        INTERFACE_INCLUDE_DIRECTORIES "${MPV_INCLUDE_DIR}"
    )
    set(MPV_VERSION "${COLORFUL_MPV_VERSION}")
else()
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(MPV REQUIRED IMPORTED_TARGET mpv>=2.0.0)
    add_library(colorful-mpv ALIAS PkgConfig::MPV)
    set(MPV_CLIENT_API_VERSION "${MPV_VERSION}")
    if(COLORFUL_MPV_MODE STREQUAL "official")
        pkg_get_variable(MPV_INSTALL_PREFIX mpv prefix)
        set(MPV_SOURCE_MARKER
            "${MPV_INSTALL_PREFIX}/share/colorful/mpv-source-version")
        if(NOT EXISTS "${MPV_SOURCE_MARKER}")
            message(FATAL_ERROR
                "Official libmpv source marker is missing: ${MPV_SOURCE_MARKER}")
        endif()
        file(READ "${MPV_SOURCE_MARKER}" MPV_VERSION)
        string(STRIP "${MPV_VERSION}" MPV_VERSION)
    else()
        set(MPV_VERSION "client-api-${MPV_CLIENT_API_VERSION}")
    endif()
endif()
if(COLORFUL_MPV_MODE STREQUAL "official"
        AND NOT MPV_VERSION STREQUAL COLORFUL_EXPECTED_MPV_VERSION)
    message(FATAL_ERROR
        "Official builds require libmpv ${COLORFUL_EXPECTED_MPV_VERSION}; found ${MPV_VERSION}")
endif()
message(STATUS "libmpv ${MPV_VERSION} (${COLORFUL_MPV_MODE} mode)")

file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/generated")
configure_file(
    src/buildinfo_generated.h.in
    "${CMAKE_CURRENT_BINARY_DIR}/generated/buildinfo_generated.h"
    @ONLY
)

qt_standard_project_setup(REQUIRES 6.8)

set(COLORFUL_DESKTOP_SOURCES
    src/main.cpp
    src/backend.cpp
    src/backend.h
    src/buildinfo.cpp
    src/buildinfo.h
    src/updatemanager.cpp
    src/updatemanager.h
    src/corebridge.cpp
    src/corebridge.h
    src/partycorebridge.cpp
    src/partycorebridge.h
    src/partyclient.cpp
    src/partyclient.h
    src/websocketclient.cpp
    src/websocketclient.h
    src/debuglog.cpp
    src/debuglog.h
    src/linuxplayback.cpp
    src/linuxplayback.h
    src/credentialstore.cpp
    src/credentialstore.h
    src/discordpresence.cpp
    src/discordpresence.h
    src/discordsocial.cpp
    src/discordsocial.h
)
if(UNIX AND NOT APPLE)
    list(APPEND COLORFUL_DESKTOP_SOURCES src/mpris.cpp src/mpris.h)
endif()
if(WIN32)
    configure_file(
        ../windows/app.manifest
        "${CMAKE_CURRENT_BINARY_DIR}/generated/app.manifest"
        COPYONLY
    )
    execute_process(
        COMMAND powershell.exe -NoProfile -ExecutionPolicy Bypass
            -File "${CMAKE_CURRENT_SOURCE_DIR}/../../scripts/convert-png-to-ico.ps1"
            -InputPath "${CMAKE_CURRENT_SOURCE_DIR}/../../assets/branding/colorful-2048.png"
            -OutputPath "${CMAKE_CURRENT_BINARY_DIR}/generated/colorful.ico"
        RESULT_VARIABLE COLORFUL_ICON_RESULT
    )
    if(NOT COLORFUL_ICON_RESULT EQUAL 0)
        message(FATAL_ERROR "Could not generate the Windows application icon")
    endif()
    configure_file(
        src/colorful.rc.in
        "${CMAKE_CURRENT_BINARY_DIR}/generated/colorful.rc"
        @ONLY
    )
    list(APPEND COLORFUL_DESKTOP_SOURCES
        src/windowsmedia.cpp
        src/windowsmedia.h
        "${CMAKE_CURRENT_BINARY_DIR}/generated/app.manifest"
        "${CMAKE_CURRENT_BINARY_DIR}/generated/colorful.rc"
    )
endif()

if(WIN32)
    qt_add_executable(colorful-linux WIN32 ${COLORFUL_DESKTOP_SOURCES})
else()
    qt_add_executable(colorful-linux ${COLORFUL_DESKTOP_SOURCES})
endif()

if(WIN32)
    set(COLORFUL_CORE_LIBRARY "${CMAKE_CURRENT_SOURCE_DIR}/../../target/debug/colorful_core.dll"
        CACHE FILEPATH "Path to the colorful-core shared library")
    set(COLORFUL_CORE_IMPORT_LIBRARY "${CMAKE_CURRENT_SOURCE_DIR}/../../target/debug/colorful_core.dll.lib"
        CACHE FILEPATH "Path to the colorful-core MSVC import library")
else()
    if(CMAKE_BUILD_TYPE STREQUAL "Release")
        set(_COLORFUL_CORE_PROFILE release)
    else()
        set(_COLORFUL_CORE_PROFILE debug)
    endif()
    set(COLORFUL_CORE_LIBRARY "${CMAKE_CURRENT_SOURCE_DIR}/../../target/${_COLORFUL_CORE_PROFILE}/libcolorful_core.so"
        CACHE FILEPATH "Path to the colorful-core shared library")
endif()
add_library(colorful-core SHARED IMPORTED GLOBAL)
if(WIN32)
    set_target_properties(colorful-core PROPERTIES
        IMPORTED_LOCATION "${COLORFUL_CORE_LIBRARY}"
        IMPORTED_IMPLIB "${COLORFUL_CORE_IMPORT_LIBRARY}"
    )
else()
    set_target_properties(colorful-core PROPERTIES
        IMPORTED_LOCATION "${COLORFUL_CORE_LIBRARY}"
        IMPORTED_NO_SONAME TRUE
    )
endif()

if(BUILD_TESTING)
    qt_add_executable(colorful-party-transport-test
        tests/partytransporttest.cpp
        src/partycorebridge.cpp
        src/partycorebridge.h
        src/websocketclient.cpp
        src/websocketclient.h
    )
    target_include_directories(colorful-party-transport-test PRIVATE
        ../../crates/colorful-core/include
        src
    )
    target_link_libraries(colorful-party-transport-test PRIVATE
        Qt6::Core
        Qt6::Network
        colorful-core
    )
    add_test(NAME colorful-party-transport
        COMMAND colorful-party-transport-test)
    set_tests_properties(colorful-party-transport PROPERTIES
        ENVIRONMENT "COLORFUL_TEST_RELAY=http://127.0.0.1:8787"
        TIMEOUT 15)

    qt_add_executable(colorful-updater-test
        tests/updatertest.cpp
        src/updatemanager.cpp
        src/updatemanager.h
        src/debuglog.cpp
        src/debuglog.h
    )
    target_include_directories(colorful-updater-test PRIVATE
        "${CMAKE_CURRENT_BINARY_DIR}/generated"
        src
    )
    target_link_libraries(colorful-updater-test PRIVATE
        Qt6::Core
        Qt6::Gui
        Qt6::Network
    )
    add_test(NAME colorful-updater COMMAND colorful-updater-test)
    set_tests_properties(colorful-updater PROPERTIES TIMEOUT 20)

    qt_add_executable(colorful-discord-presence-test
        tests/discordpresencetest.cpp
        src/discordpresence.cpp
        src/discordpresence.h
        src/debuglog.cpp
        src/debuglog.h
    )
    target_include_directories(colorful-discord-presence-test PRIVATE src)
    target_link_libraries(colorful-discord-presence-test PRIVATE Qt6::Core Qt6::Network)
    add_test(NAME colorful-discord-presence COMMAND colorful-discord-presence-test)
    set_tests_properties(colorful-discord-presence PROPERTIES TIMEOUT 10)
endif()
target_include_directories(colorful-linux PRIVATE
    ../../crates/colorful-core/include
    "${CMAKE_CURRENT_BINARY_DIR}/generated"
)
if(WIN32)
    set_target_properties(colorful-linux PROPERTIES OUTPUT_NAME colorful)
else()
    set_target_properties(colorful-linux PROPERTIES INSTALL_RPATH "$ORIGIN/../lib")
endif()

qt_add_qml_module(colorful-linux
    URI colorful
    VERSION 1.0
    QML_FILES
        qml/Main.qml
        qml/HomePage.qml
        qml/ShelfScrollButtons.qml
        qml/ProviderHeader.qml
        qml/AppIcon.qml
        qml/ColorButton.qml
        qml/IconButton.qml
        qml/ResizeHandle.qml
        qml/TitleButton.qml
        qml/TrackDelegate.qml
        qml/CatalogCard.qml
        qml/CatalogPage.qml
        qml/PlaylistCard.qml
        qml/TidalPage.qml
        qml/YouTubePage.qml
        qml/SoundCloudPage.qml
        qml/DownloadsPage.qml
        qml/LibraryPage.qml
        qml/LyricsPanel.qml
        qml/ToastOverlay.qml
        qml/AccountCard.qml
        qml/ProviderAccountCard.qml
        qml/SettingsPage.qml
        qml/OnboardingPage.qml
        qml/MetadataLink.qml
        qml/ArtworkImage.qml
        qml/PartySidePanel.qml
    RESOURCES
        qml/icons/add.svg
        qml/icons/close.svg
        qml/icons/download.svg
        qml/icons/home.svg
        qml/icons/library.svg
        qml/icons/lyrics.svg
        qml/icons/maximize.svg
        qml/icons/minimize.svg
        qml/icons/music.svg
        qml/icons/next.svg
        qml/icons/pause-dark.svg
        qml/icons/pause.svg
        qml/icons/play-dark.svg
        qml/icons/play.svg
        qml/icons/previous.svg
        qml/icons/queue.svg
        qml/icons/restore.svg
        qml/icons/search.svg
        qml/icons/settings.svg
        qml/icons/soundcloud.svg
        qml/icons/tidal.svg
        qml/icons/youtube.svg
        qml/icons/user.svg
        qml/icons/volume.svg
        qml/icons/volume-muted.svg
        qml/icons/shuffle.svg
        qml/icons/repeat.svg
        qml/icons/repeat-one.svg
)

set_source_files_properties(
    ../../assets/fonts/Nunito.ttf PROPERTIES QT_RESOURCE_ALIAS fonts/Nunito.ttf
)
set_source_files_properties(
    ../../assets/fonts/OFL.txt PROPERTIES QT_RESOURCE_ALIAS fonts/OFL.txt
)
set_source_files_properties(
    ../../assets/branding/colorful.svg PROPERTIES QT_RESOURCE_ALIAS branding/colorful.svg
)
set_source_files_properties(
    ../../assets/branding/colorful-2048.png PROPERTIES QT_RESOURCE_ALIAS branding/colorful-2048.png
)
qt_add_resources(colorful-linux colorful_assets
    PREFIX "/assets"
    FILES
        ../../assets/fonts/Nunito.ttf
        ../../assets/fonts/OFL.txt
        ../../assets/branding/colorful.svg
        ../../assets/branding/colorful-2048.png
)

target_compile_definitions(colorful-linux PRIVATE
    COLORFUL_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../.."
)

target_link_libraries(colorful-linux PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::Network
    colorful-mpv
    colorful-core
    colorful-discord-social
    ${CMAKE_DL_LIBS}
)
if(UNIX AND NOT APPLE)
    target_link_libraries(colorful-linux PRIVATE Qt6::DBus)
endif()
if(WIN32)
    target_link_libraries(colorful-linux PRIVATE Advapi32 Crypt32 WindowsApp)
    add_custom_command(TARGET colorful-linux POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "${COLORFUL_CORE_LIBRARY}" "$<TARGET_FILE_DIR:colorful-linux>"
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "${MPV_RUNTIME}" "$<TARGET_FILE_DIR:colorful-linux>"
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "${COLORFUL_DISCORD_SDK_RUNTIME}" "$<TARGET_FILE_DIR:colorful-linux>"
        VERBATIM
    )
    qt_add_executable(colorful-credential-helper
        src/credentialhelpermain.cpp
        src/credentialstore.cpp
        src/credentialstore.h
    )
    target_link_libraries(colorful-credential-helper PRIVATE Qt6::Core Crypt32)
endif()

install(TARGETS colorful-linux RUNTIME DESTINATION bin)
if(WIN32)
    install(FILES "${COLORFUL_CORE_LIBRARY}" "${MPV_RUNTIME}" "${COLORFUL_DISCORD_SDK_RUNTIME}" DESTINATION bin)
else()
    install(FILES "${COLORFUL_CORE_LIBRARY}" "${COLORFUL_DISCORD_SDK_RUNTIME}" DESTINATION lib)
    install(FILES "${COLORFUL_DISCORD_SDK_ROOT}/License-Notices.txt"
        DESTINATION share/doc/colorful
        RENAME DISCORD_SOCIAL_SDK_NOTICES.txt)
    install(FILES applications/colorful.desktop
        DESTINATION share/applications
        RENAME sh.valerie.colorful.desktop
    )
    install(FILES applications/colorful.metainfo.xml
        DESTINATION share/metainfo
        RENAME sh.valerie.colorful.appdata.xml
    )
    install(FILES ../../assets/branding/colorful.svg
        DESTINATION share/icons/hicolor/scalable/apps
        RENAME colorful.svg
    )
endif()
