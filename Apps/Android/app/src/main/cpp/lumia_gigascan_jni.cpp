#include <jni.h>
#include <dlfcn.h>

#include <cstdint>
#include <mutex>

namespace {
using AbiFunction = uint32_t (*)();
using PlanFunction = char* (*)(const char*);
using ProgressFunction = void (*)(const char*, float, void*);
using StitchFunction = char* (*)(const char*, ProgressFunction, void*);
using FreeFunction = void (*)(char*);

struct CoreSymbols {
  void* handle = nullptr;
  AbiFunction abi = nullptr;
  PlanFunction plan = nullptr;
  StitchFunction stitch = nullptr;
  FreeFunction free_value = nullptr;
};

CoreSymbols& symbols() {
  static CoreSymbols value;
  static std::once_flag once;
  std::call_once(once, [] {
    value.handle = dlopen("liblumia_gigascan_core.so", RTLD_NOW | RTLD_LOCAL);
    if (!value.handle) return;
    value.abi = reinterpret_cast<AbiFunction>(
        dlsym(value.handle, "lumia_gigascan_abi_version"));
    value.plan = reinterpret_cast<PlanFunction>(
        dlsym(value.handle, "lumia_gigascan_plan_json"));
    value.stitch = reinterpret_cast<StitchFunction>(
        dlsym(value.handle, "lumia_gigascan_stitch_json"));
    value.free_value = reinterpret_cast<FreeFunction>(
        dlsym(value.handle, "lumia_gigascan_free"));
  });
  return value;
}

jstring invoke(JNIEnv* env, jstring request, PlanFunction function) {
  if (!request || !function) return nullptr;
  const char* input = env->GetStringUTFChars(request, nullptr);
  if (!input) return nullptr;
  char* response = function(input);
  env->ReleaseStringUTFChars(request, input);
  if (!response) return nullptr;
  jstring result = env->NewStringUTF(response);
  symbols().free_value(response);
  return result;
}

jstring invoke(JNIEnv* env, jstring request, StitchFunction function) {
  if (!request || !function) return nullptr;
  const char* input = env->GetStringUTFChars(request, nullptr);
  if (!input) return nullptr;
  char* response = function(input, nullptr, nullptr);
  env->ReleaseStringUTFChars(request, input);
  if (!response) return nullptr;
  jstring result = env->NewStringUTF(response);
  symbols().free_value(response);
  return result;
}
}  // namespace

extern "C" JNIEXPORT jboolean JNICALL
Java_com_opencapture_openpocketcine_gigascan_LumiaGigaScanCoreBridge_nativeIsAvailable(
    JNIEnv*, jobject) {
  const auto& core = symbols();
  return core.abi && core.plan && core.stitch && core.free_value &&
      core.abi() == 1;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_opencapture_openpocketcine_gigascan_LumiaGigaScanCoreBridge_nativeAbiVersion(
    JNIEnv*, jobject) {
  const auto& core = symbols();
  return core.abi ? static_cast<jint>(core.abi()) : 0;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_opencapture_openpocketcine_gigascan_LumiaGigaScanCoreBridge_nativePlanJson(
    JNIEnv* env, jobject, jstring request) {
  const auto& core = symbols();
  return core.free_value ? invoke(env, request, core.plan) : nullptr;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_opencapture_openpocketcine_gigascan_LumiaGigaScanCoreBridge_nativeStitchJson(
    JNIEnv* env, jobject, jstring request) {
  const auto& core = symbols();
  return core.free_value ? invoke(env, request, core.stitch) : nullptr;
}
