cmake_minimum_required(VERSION 3.25)

set(COLORFUL_VERSION_FILE "${CMAKE_CURRENT_SOURCE_DIR}/../../VERSION")
file(STRINGS "${COLORFUL_VERSION_FILE}" COLORFUL_APP_VERSION LIMIT_COUNT 1)
if(NOT COLORFUL_APP_VERSION MATCHES "^[0-9]+\\.[0-9]+\\.[0-9]+$")
    message(FATAL_ERROR "VERSION must contain a three-part numeric version such as 0.2.0")
endif()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${COLORFUL_VERSION_FILE}")

project(colorfulDesktop VERSION "${COLORFUL_APP_VERSION}" LANGUAGES CXX)
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

file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/generated")
configure_file(
    src/buildinfo_generated.h.in
    "${CMAKE_CURRENT_BINARY_DIR}/generated/buildinfo_generated.h"
    @ONLY
)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui Quick QuickControls2 Network)
if(UNIX AND NOT APPLE)
    find_package(Qt6 6.8 REQUIRED COMPONENTS DBus)
endif()

if(WIN32)
    set(COLORFUL_MPV_ROOT "" CACHE PATH "Root of a Windows libmpv development package")
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
    set(MPV_VERSION "Windows bundle")
else()
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(MPV REQUIRED IMPORTED_TARGET mpv)
    add_library(colorful-mpv ALIAS PkgConfig::MPV)
endif()

qt_standard_project_setup(REQUIRES 6.8)

set(COLORFUL_DESKTOP_SOURCES
    src/main.cpp
    src/backend.cpp
    src/backend.h
    src/buildinfo.cpp
    src/buildinfo.h
    src/corebridge.cpp
    src/corebridge.h
    src/debuglog.cpp
    src/debuglog.h
    src/linuxplayback.cpp
    src/linuxplayback.h
    src/discordpresence.cpp
    src/discordpresence.h
    src/discordwidget.cpp
    src/discordwidget.h
)
if(UNIX AND NOT APPLE)
    list(APPEND COLORFUL_DESKTOP_SOURCES src/mpris.cpp src/mpris.h)
endif()
if(WIN32)
    configure_file(
        src/colorful.rc.in
        "${CMAKE_CURRENT_BINARY_DIR}/generated/colorful.rc"
        @ONLY
    )
    list(APPEND COLORFUL_DESKTOP_SOURCES
        src/credentialstore.cpp
        src/credentialstore.h
        src/windowsmedia.cpp
        src/windowsmedia.h
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
qt_add_resources(colorful-linux colorful_assets
    PREFIX "/assets"
    FILES
        ../../assets/fonts/Nunito.ttf
        ../../assets/fonts/OFL.txt
        ../../assets/branding/colorful.svg
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
    install(FILES "${COLORFUL_CORE_LIBRARY}" "${MPV_RUNTIME}" DESTINATION bin)
else()
    install(FILES "${COLORFUL_CORE_LIBRARY}" DESTINATION lib)
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
