#include <jni.h>

#include <cstdint>
#include <cstring>
#include <vector>

#include "colorful_core.h"

namespace {
std::vector<char> bytes(JNIEnv* env, jbyteArray input) {
    const jsize length = env->GetArrayLength(input);
    std::vector<char> value(static_cast<size_t>(length) + 1, '\0');
    env->GetByteArrayRegion(input, 0, length, reinterpret_cast<jbyte*>(value.data()));
    return value;
}

jbyteArray response(JNIEnv* env, char* value) {
    if (value == nullptr) return env->NewByteArray(0);
    const auto length = static_cast<jsize>(std::strlen(value));
    jbyteArray output = env->NewByteArray(length);
    env->SetByteArrayRegion(output, 0, length, reinterpret_cast<const jbyte*>(value));
    colorful_string_free(value);
    return output;
}
}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_sh_valerie_colorful_NativeCore_abiVersion(JNIEnv*, jobject) {
    return static_cast<jint>(colorful_core_abi_version());
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_sh_valerie_colorful_NativeCore_open(JNIEnv* env, jobject, jbyteArray path) {
    auto value = bytes(env, path);
    return response(env, colorful_engine_open(value.data()));
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_sh_valerie_colorful_NativeCore_dispatch(JNIEnv* env, jobject, jlong handle, jbyteArray command) {
    auto value = bytes(env, command);
    return response(env, colorful_engine_dispatch(static_cast<uint64_t>(handle), value.data()));
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_sh_valerie_colorful_NativeCore_snapshot(JNIEnv* env, jobject, jlong handle) {
    return response(env, colorful_engine_snapshot(static_cast<uint64_t>(handle)));
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_sh_valerie_colorful_NativeCore_mapTidalTracks(JNIEnv* env, jobject, jbyteArray document) {
    auto value = bytes(env, document);
    return response(env, colorful_tidal_map_tracks(value.data()));
}
extern "C" JNIEXPORT jboolean JNICALL
Java_sh_valerie_colorful_NativeCore_close(JNIEnv*, jobject, jlong handle) {
    return colorful_engine_close(static_cast<uint64_t>(handle)) ? JNI_TRUE : JNI_FALSE;
}
