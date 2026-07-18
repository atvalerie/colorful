cmake_minimum_required(VERSION 3.25)

project(ColorfulLinux VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui Quick QuickControls2 Multimedia Network DBus)

qt_standard_project_setup(REQUIRES 6.8)

qt_add_executable(colorful-linux
    src/main.cpp
    src/backend.cpp
    src/backend.h
    src/mpris.cpp
    src/mpris.h
)

qt_add_qml_module(colorful-linux
    URI Colorful
    VERSION 1.0
    QML_FILES
        qml/Main.qml
        qml/ColorButton.qml
        qml/TrackDelegate.qml
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
    Qt6::Multimedia
    Qt6::Network
    Qt6::DBus
)

install(TARGETS colorful-linux RUNTIME DESTINATION bin)
install(FILES applications/colorful.desktop DESTINATION share/applications)
