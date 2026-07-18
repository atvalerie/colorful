cmake_minimum_required(VERSION 3.22.1)
project(colorful_android LANGUAGES CXX)

add_library(colorful_core SHARED IMPORTED)
set_target_properties(colorful_core PROPERTIES
    IMPORTED_LOCATION "${COLORFUL_CORE_DIR}/${ANDROID_ABI}/libcolorful_core.so")
add_library(colorful_jni SHARED colorful_jni.cpp)
target_compile_features(colorful_jni PRIVATE cxx_std_17)
target_include_directories(colorful_jni PRIVATE
    "${CMAKE_CURRENT_LIST_DIR}/../../../../../../crates/colorful-core/include")
target_link_libraries(colorful_jni PRIVATE colorful_core log)
