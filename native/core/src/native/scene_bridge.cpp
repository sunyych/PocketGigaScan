#include <cstddef>
#include <cstdint>
#include <cwchar>
#ifdef LUMIA_SCENE_ORT
#define ORT_API_MANUAL_INIT
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <onnxruntime_cxx_api.h>
#include <windows.h>
#include <algorithm>
#include <cstring>
#include <string>
#include <array>
#include <stdexcept>
#include <cwchar>
#include <mutex>
#include <memory>

namespace {
HMODULE g_runtime = nullptr;
const OrtApiBase* g_base = nullptr;
std::once_flag g_runtime_once;
std::wstring module_directory() {
  HMODULE module = nullptr;
  if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
      reinterpret_cast<LPCWSTR>(&module_directory), &module)) throw std::runtime_error("could not locate the native core module");
  std::wstring path(32768, L'\0');
  const DWORD length = GetModuleFileNameW(module, path.data(), static_cast<DWORD>(path.size()));
  if (length == 0 || length >= path.size()) throw std::runtime_error("could not resolve the native core module path");
  path.resize(length);
  const auto separator = path.find_last_of(L"\\/");
  if (separator == std::wstring::npos) throw std::runtime_error("native core module path has no directory");
  path.resize(separator);
  return path;
}
void set_error(wchar_t* out, size_t capacity, const std::wstring& message) {
  if (!out || capacity == 0) return;
  const size_t n = std::min(capacity - 1, message.size());
  std::wmemcpy(out, message.data(), n); out[n] = 0;
}
std::wstring widen(const char* text) {
  if (!text) return L"unknown ONNX Runtime error";
  const int n = MultiByteToWideChar(CP_UTF8, 0, text, -1, nullptr, 0);
  if (n <= 0) return L"ONNX Runtime error";
  std::wstring result(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text, -1, result.data(), n);
  if (!result.empty() && result.back() == L'\0') result.pop_back();
  return result;
}
struct SceneSession { Ort::Env env{ORT_LOGGING_LEVEL_WARNING, "PocketGigaScan scene"}; Ort::SessionOptions options; std::unique_ptr<Ort::Session> session; };
}

extern "C" __declspec(dllexport) int lumia_scene_open(const wchar_t* model, uint32_t intra_op_threads, void** result, wchar_t* error, size_t cap) {
  try {
    if (!model || !result) throw std::runtime_error("missing model/session path");
    const std::wstring runtime_path = module_directory() + L"\\onnxruntime.dll";
    std::call_once(g_runtime_once, [&]() {
      HMODULE module = LoadLibraryExW(runtime_path.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
      if (!module) throw std::runtime_error("LoadLibraryExW failed for the packaged onnxruntime.dll");
      auto get_base = reinterpret_cast<decltype(&OrtGetApiBase)>(GetProcAddress(module, "OrtGetApiBase"));
      if (!get_base) { FreeLibrary(module); throw std::runtime_error("onnxruntime.dll does not export OrtGetApiBase"); }
      const OrtApiBase* base = get_base();
      if (!base) { FreeLibrary(module); throw std::runtime_error("OrtGetApiBase returned null"); }
      const OrtApi* api = base->GetApi(ORT_API_VERSION);
      if (!api) { FreeLibrary(module); throw std::runtime_error("onnxruntime.dll does not support the compiled ONNX Runtime API version"); }
      Ort::InitApi(api);
      g_base = base;
      g_runtime = module;
    });
    if (!g_base || !g_runtime) throw std::runtime_error("ONNX Runtime initialization did not complete");
    std::unique_ptr<SceneSession> state(new SceneSession());
    state->env.DisableTelemetryEvents();
    state->options.SetIntraOpNumThreads(static_cast<int>(std::clamp<uint32_t>(intra_op_threads, 1, 8)));
    state->options.SetInterOpNumThreads(1);
    state->options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
    state->session = std::make_unique<Ort::Session>(state->env, model, state->options);
    if (state->session->GetInputCount() != 1 || state->session->GetOutputCount() != 1) throw std::runtime_error("scene ONNX graph must expose one input and one output");
    auto input_name = state->session->GetInputNameAllocated(0, Ort::AllocatorWithDefaultOptions());
    auto output_name = state->session->GetOutputNameAllocated(0, Ort::AllocatorWithDefaultOptions());
    if (std::strcmp(input_name.get(), "pixel_values") != 0 || std::strcmp(output_name.get(), "scene_probabilities") != 0) throw std::runtime_error("scene ONNX input/output names do not match the pinned model contract");
    const auto input_info = state->session->GetInputTypeInfo(0).GetTensorTypeAndShapeInfo();
    const auto input_shape = input_info.GetShape();
    if (input_info.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || input_shape != std::vector<int64_t>{1,3,512,512}) throw std::runtime_error("scene ONNX input must be float32 [1,3,512,512]");
    const auto output_info = state->session->GetOutputTypeInfo(0).GetTensorTypeAndShapeInfo();
    const auto output_shape = output_info.GetShape();
    if (output_info.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || output_shape != std::vector<int64_t>{1,2,512,512}) throw std::runtime_error("scene ONNX output must be float32 [1,2,512,512] person/water probabilities");
    *result = state.release();
    return 0;
  } catch (const Ort::Exception& e) { set_error(error, cap, widen(e.what())); }
    catch (const std::exception& e) { set_error(error, cap, widen(e.what())); }
    catch (...) { set_error(error, cap, L"unknown scene runtime initialization error"); }
  return 1;
}

extern "C" __declspec(dllexport) int lumia_scene_infer(void* opaque, const float* input, float* output, size_t output_len, wchar_t* error, size_t cap) {
  try {
    if (!opaque || !input || !output || output_len != 2u * 512u * 512u) throw std::runtime_error("invalid scene inference buffers");
    auto* state = static_cast<SceneSession*>(opaque);
    const std::array<int64_t, 4> shape{1, 3, 512, 512};
    auto memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    auto tensor = Ort::Value::CreateTensor<float>(memory, const_cast<float*>(input), 3u*512u*512u, shape.data(), shape.size());
    auto input_name = state->session->GetInputNameAllocated(0, Ort::AllocatorWithDefaultOptions());
    auto output_name = state->session->GetOutputNameAllocated(0, Ort::AllocatorWithDefaultOptions());
    const char* input_names[] = {input_name.get()}; const char* output_names[] = {output_name.get()};
    auto values = state->session->Run(Ort::RunOptions{nullptr}, input_names, &tensor, 1, output_names, 1);
    if (values.size() != 1 || !values[0].IsTensor()) throw std::runtime_error("scene ONNX output is not a tensor");
    auto info = values[0].GetTensorTypeAndShapeInfo();
    const auto dims = info.GetShape();
    if (dims.size() != 4 || dims[0] != 1 || dims[1] != 2 || dims[2] != 512 || dims[3] != 512 || info.GetElementCount() != output_len) throw std::runtime_error("scene ONNX output must be [1,2,512,512] person/water probabilities");
    std::memcpy(output, values[0].GetTensorData<float>(), output_len*sizeof(float));
    return 0;
  } catch (const Ort::Exception& e) { set_error(error, cap, widen(e.what())); }
    catch (const std::exception& e) { set_error(error, cap, widen(e.what())); }
    catch (...) { set_error(error, cap, L"unknown scene inference error"); }
  return 1;
}

extern "C" __declspec(dllexport) void lumia_scene_close(void* opaque) {
  auto* state = static_cast<SceneSession*>(opaque);
  if (!state) return;
  delete state;
}
#else
extern "C" __declspec(dllexport) int lumia_scene_open(const wchar_t*, uint32_t, void**, wchar_t* error, size_t cap) {
  if (error && cap) { const wchar_t message[] = L"scene analysis is unavailable because this build has no pinned ONNX Runtime SDK"; const size_t n = (sizeof(message)/sizeof(wchar_t)-1 < cap-1) ? sizeof(message)/sizeof(wchar_t)-1 : cap-1; std::wmemcpy(error,message,n);error[n]=0; }
  return 1;
}
extern "C" __declspec(dllexport) int lumia_scene_infer(void*, const float*, float*, size_t, wchar_t*, size_t) { return 1; }
extern "C" __declspec(dllexport) void lumia_scene_close(void*) {}
#endif
