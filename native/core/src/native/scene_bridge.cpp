#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <vector>

#ifdef LUMIA_SCENE_ORT
#define ORT_API_MANUAL_INIT
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#endif
#include <onnxruntime_cxx_api.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace {
#ifdef _WIN32
HMODULE g_runtime = nullptr;
#else
void* g_runtime = nullptr;
#endif
const OrtApiBase* g_base = nullptr;
std::once_flag g_runtime_once;

void set_error(char* out, size_t capacity, const char* message) {
  if (!out || capacity == 0) return;
  if (!message) message = "unknown scene runtime error";
  const size_t length = std::min(capacity - 1, std::strlen(message));
  std::memcpy(out, message, length);
  out[length] = '\0';
}

#ifdef _WIN32
std::wstring utf8_to_wide(const char* text) {
  if (!text) throw std::runtime_error("missing UTF-8 model path");
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, nullptr, 0);
  if (length <= 0) throw std::runtime_error("model path is not valid UTF-8");
  std::wstring result(static_cast<size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, result.data(), length) <= 0)
    throw std::runtime_error("model path is not valid UTF-8");
  result.pop_back();
  return result;
}

std::wstring runtime_path() {
  HMODULE module = nullptr;
  if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
      reinterpret_cast<LPCWSTR>(&runtime_path), &module))
    throw std::runtime_error("could not locate the native core module");
  std::wstring path(32768, L'\0');
  const DWORD length = GetModuleFileNameW(module, path.data(), static_cast<DWORD>(path.size()));
  if (length == 0 || length >= path.size()) throw std::runtime_error("could not resolve the native core module path");
  path.resize(length);
  const auto separator = path.find_last_of(L"\\/");
  if (separator == std::wstring::npos) throw std::runtime_error("native core module path has no directory");
  path.resize(separator + 1);
  path += L"onnxruntime.dll";
  return path;
}
#else
std::string runtime_path() {
  Dl_info info{};
  if (dladdr(reinterpret_cast<const void*>(&runtime_path), &info) == 0 || !info.dli_fname)
    throw std::runtime_error("could not locate the native core module with dladdr");
  std::string path(info.dli_fname);
  if (path.empty() || path.front() != '/')
    throw std::runtime_error("dladdr did not return an absolute native core module path");
  const auto separator = path.find_last_of('/');
  if (separator == std::string::npos) throw std::runtime_error("native core module path has no directory");
  path.resize(separator + 1);
  path += "libonnxruntime.dylib";
  return path;
}
#endif

void initialize_runtime() {
#ifdef _WIN32
  const std::wstring path = runtime_path();
  HMODULE module = LoadLibraryExW(path.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
  if (!module) throw std::runtime_error("LoadLibraryExW failed for the packaged onnxruntime.dll beside the native core");
  std::unique_ptr<std::remove_pointer<HMODULE>::type, decltype(&FreeLibrary)> guard(module, &FreeLibrary);
  auto get_base = reinterpret_cast<decltype(&OrtGetApiBase)>(GetProcAddress(module, "OrtGetApiBase"));
#else
  const std::string path = runtime_path();
  void* module = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (!module) {
    const char* detail = dlerror();
    throw std::runtime_error(std::string("dlopen failed for the packaged libonnxruntime.dylib beside the native core") +
        (detail ? std::string(": ") + detail : std::string()));
  }
  std::unique_ptr<void, decltype(&dlclose)> guard(module, &dlclose);
  dlerror();
  auto get_base = reinterpret_cast<decltype(&OrtGetApiBase)>(dlsym(module, "OrtGetApiBase"));
  const char* symbol_error = dlerror();
  if (symbol_error) throw std::runtime_error(std::string("libonnxruntime.dylib does not export OrtGetApiBase: ") + symbol_error);
#endif
  if (!get_base) throw std::runtime_error("ONNX Runtime library does not export OrtGetApiBase");
  const OrtApiBase* base = get_base();
  if (!base) throw std::runtime_error("OrtGetApiBase returned null");
  const OrtApi* api = base->GetApi(ORT_API_VERSION);
  if (!api) throw std::runtime_error("ONNX Runtime does not support the compiled API version");
  Ort::InitApi(api);
  g_base = base;
  g_runtime = module;
  guard.release();
}

void ensure_runtime() {
  std::call_once(g_runtime_once, initialize_runtime);
  if (!g_base || !g_runtime) throw std::runtime_error("ONNX Runtime initialization did not complete");
}

struct SceneSession {
  Ort::Env env{ORT_LOGGING_LEVEL_WARNING, "PocketGigaScan scene"};
  Ort::SessionOptions options;
  std::unique_ptr<Ort::Session> session;
};

void validate_model_contract(Ort::Session& session) {
  if (session.GetInputCount() != 1 || session.GetOutputCount() != 1)
    throw std::runtime_error("scene ONNX graph must expose one input and one output");
  auto input_name = session.GetInputNameAllocated(0, Ort::AllocatorWithDefaultOptions());
  auto output_name = session.GetOutputNameAllocated(0, Ort::AllocatorWithDefaultOptions());
  if (std::strcmp(input_name.get(), "pixel_values") != 0 || std::strcmp(output_name.get(), "scene_probabilities") != 0)
    throw std::runtime_error("scene ONNX input/output names do not match the pinned model contract");
  const auto input_type_info = session.GetInputTypeInfo(0);
  const auto input_info = input_type_info.GetTensorTypeAndShapeInfo();
  if (input_info.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT ||
      input_info.GetShape() != std::vector<int64_t>{1, 3, 512, 512})
    throw std::runtime_error("scene ONNX input must be float32 [1,3,512,512]");
  const auto output_type_info = session.GetOutputTypeInfo(0);
  const auto output_info = output_type_info.GetTensorTypeAndShapeInfo();
  if (output_info.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT ||
      output_info.GetShape() != std::vector<int64_t>{1, 2, 512, 512})
    throw std::runtime_error("scene ONNX output must be float32 [1,2,512,512] person/water probabilities");
}
}  // namespace

extern "C" int lumia_scene_open(const char* model_utf8, uint32_t intra_op_threads, void** result, char* error, size_t cap) {
  if (result) *result = nullptr;
  try {
    if (!model_utf8 || !result) throw std::runtime_error("missing model/session path");
    ensure_runtime();
    std::unique_ptr<SceneSession> state(new SceneSession());
    state->env.DisableTelemetryEvents();
    state->options.SetIntraOpNumThreads(static_cast<int>(std::clamp<uint32_t>(intra_op_threads, 1, 8)));
    state->options.SetInterOpNumThreads(1);
    state->options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
#ifdef _WIN32
    const std::wstring model = utf8_to_wide(model_utf8);
    state->session = std::make_unique<Ort::Session>(state->env, model.c_str(), state->options);
#else
    state->session = std::make_unique<Ort::Session>(state->env, model_utf8, state->options);
#endif
    validate_model_contract(*state->session);
    *result = state.release();
    return 0;
  } catch (const Ort::Exception& e) { set_error(error, cap, e.what()); }
    catch (const std::exception& e) { set_error(error, cap, e.what()); }
    catch (...) { set_error(error, cap, "unknown scene runtime initialization error"); }
  return 1;
}

extern "C" int lumia_scene_infer(void* opaque, const float* input, float* output, size_t output_len, char* error, size_t cap) {
  try {
    if (!opaque || !input || !output || output_len != 2u * 512u * 512u)
      throw std::runtime_error("invalid scene inference buffers");
    auto* state = static_cast<SceneSession*>(opaque);
    const std::array<int64_t, 4> shape{1, 3, 512, 512};
    auto memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    auto tensor = Ort::Value::CreateTensor<float>(memory, const_cast<float*>(input), 3u * 512u * 512u, shape.data(), shape.size());
    auto input_name = state->session->GetInputNameAllocated(0, Ort::AllocatorWithDefaultOptions());
    auto output_name = state->session->GetOutputNameAllocated(0, Ort::AllocatorWithDefaultOptions());
    const char* input_names[] = {input_name.get()};
    const char* output_names[] = {output_name.get()};
    auto values = state->session->Run(Ort::RunOptions{nullptr}, input_names, &tensor, 1, output_names, 1);
    if (values.size() != 1 || !values[0].IsTensor()) throw std::runtime_error("scene ONNX output is not a tensor");
    const auto info = values[0].GetTensorTypeAndShapeInfo();
    const auto dims = info.GetShape();
    if (dims != std::vector<int64_t>{1, 2, 512, 512} || info.GetElementCount() != output_len)
      throw std::runtime_error("scene ONNX output must be [1,2,512,512] person/water probabilities");
    std::memcpy(output, values[0].GetTensorData<float>(), output_len * sizeof(float));
    return 0;
  } catch (const Ort::Exception& e) { set_error(error, cap, e.what()); }
    catch (const std::exception& e) { set_error(error, cap, e.what()); }
    catch (...) { set_error(error, cap, "unknown scene inference error"); }
  return 1;
}

extern "C" void lumia_scene_close(void* opaque) {
  delete static_cast<SceneSession*>(opaque);
}
#else
namespace {
void set_error(char* error, size_t capacity) {
  static constexpr char message[] = "scene analysis is unavailable because this build has no pinned ONNX Runtime SDK";
  if (!error || capacity == 0) return;
  const size_t length = std::min(capacity - 1, sizeof(message) - 1);
  std::memcpy(error, message, length);
  error[length] = '\0';
}
}
extern "C" int lumia_scene_open(const char*, uint32_t, void** result, char* error, size_t cap) {
  if (result) *result = nullptr;
  set_error(error, cap);
  return 1;
}
extern "C" int lumia_scene_infer(void*, const float*, float*, size_t, char* error, size_t cap) {
  set_error(error, cap);
  return 1;
}
extern "C" void lumia_scene_close(void*) {}
#endif
