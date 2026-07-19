cmake_minimum_required(VERSION 3.25)

project(colorfulLinux VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui Quick QuickControls2 Network DBus)
find_package(PkgConfig REQUIRED)
pkg_check_modules(GSTREAMER REQUIRED IMPORTED_TARGET
    gstreamer-1.0
    gstreamer-audio-1.0
    gstreamer-controller-1.0
)

qt_standard_project_setup(REQUIRES 6.8)

qt_add_executable(colorful-linux
    src/main.cpp
    src/backend.cpp
    src/backend.h
    src/corebridge.cpp
    src/corebridge.h
    src/linuxplayback.cpp
    src/linuxplayback.h
    src/discordpresence.cpp
    src/discordpresence.h
    src/mpris.cpp
    src/mpris.h
)

set(COLORFUL_CORE_LIBRARY "${CMAKE_CURRENT_SOURCE_DIR}/../../target/debug/libcolorful_core.so"
    CACHE FILEPATH "Path to the colorful-core shared library")
add_library(colorful-core SHARED IMPORTED GLOBAL)
set_target_properties(colorful-core PROPERTIES
    IMPORTED_LOCATION "${COLORFUL_CORE_LIBRARY}"
    IMPORTED_NO_SONAME TRUE
)
target_include_directories(colorful-linux PRIVATE ../../crates/colorful-core/include)
set_target_properties(colorful-linux PROPERTIES INSTALL_RPATH "$ORIGIN/../lib")

qt_add_qml_module(colorful-linux
    URI colorful
    VERSION 1.0
    QML_FILES
        qml/Main.qml
        qml/AppIcon.qml
        qml/ColorButton.qml
        qml/IconButton.qml
        qml/ResizeHandle.qml
        qml/TitleButton.qml
        qml/TrackDelegate.qml
    RESOURCES
        qml/icons/add.svg
        qml/icons/close.svg
        qml/icons/download.svg
        qml/icons/home.svg
        qml/icons/library.svg
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
        qml/icons/user.svg
        qml/icons/volume.svg
)

set_source_files_properties(
    ../../assets/fonts/Nunito.ttf PROPERTIES QT_RESOURCE_ALIAS fonts/Nunito.ttf
)
set_source_files_properties(
    ../../assets/fonts/OFL.txt PROPERTIES QT_RESOURCE_ALIAS fonts/OFL.txt
)
qt_add_resources(colorful-linux colorful_assets
    PREFIX "/assets"
    FILES
        ../../assets/fonts/Nunito.ttf
        ../../assets/fonts/OFL.txt
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
    Qt6::DBus
    PkgConfig::GSTREAMER
    colorful-core
    ${CMAKE_DL_LIBS}
)

install(TARGETS colorful-linux RUNTIME DESTINATION bin)
install(FILES "${COLORFUL_CORE_LIBRARY}" DESTINATION lib)
install(FILES applications/colorful.desktop DESTINATION share/applications)
