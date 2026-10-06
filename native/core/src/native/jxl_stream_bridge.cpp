#include <jxl/color_encoding.h>
#include <jxl/codestream_header.h>
#include <jxl/encode.h>
#include <jxl/parallel_runner.h>
#include <jxl/types.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <vector>

namespace {
// libjxl 0.12.0 documents a 2048 maximum, but its real 9943x5639 callback
// requested 2056x2056 (2048 plus one 8-pixel block). Keep a tight aligned cap.
constexpr size_t kMaxChunkDimension = 2064u;
constexpr size_t kMaxChunk = kMaxChunkDimension * kMaxChunkDimension;
constexpr size_t kFallbackBytes = kMaxChunk * 4u;
constexpr uint64_t kMaxActiveChunkBytes = 64ull * 1024ull * 1024ull;
constexpr size_t kOutputBufferBytes = 64u * 1024u;
constexpr size_t kMaxDimension = 131072u;

using CheckpointFn = int (*)(void*);

#if defined(_WIN32)
using NativePathChar = wchar_t;
#else
using NativePathChar = char;
#endif

void set_error(char* output, size_t capacity, const char* message) noexcept {
  if (output == nullptr || capacity == 0) return;
  std::snprintf(output, capacity, "%s", message == nullptr ? "libjxl error" : message);
}

struct EncodeContext {
  std::ifstream input;
  std::fstream output;
  uint32_t width = 0;
  uint32_t height = 0;
  CheckpointFn checkpoint = nullptr;
  void* checkpoint_opaque = nullptr;
  std::unique_ptr<uint8_t[]> fallback;
  std::array<uint8_t, kOutputBufferBytes> output_buffer{};
  std::mutex input_mutex;
  std::mutex output_mutex;
  std::atomic<bool> source_error{false};
  std::atomic<int> source_error_code{0};
  uint64_t source_error_x = 0;
  uint64_t source_error_y = 0;
  uint64_t source_error_width = 0;
  uint64_t source_error_height = 0;
  uint64_t source_error_row = 0;
  uint64_t source_error_index = 0;
  std::atomic<bool> output_error{false};
  std::atomic<bool> cancelled{false};
  std::atomic<uint64_t> active_chunk_bytes{0};
  std::atomic<uint64_t> peak_chunk_bytes{0};
  uint64_t active_chunk_limit_bytes = kMaxActiveChunkBytes;
  uint64_t output_position = 0;
  uint64_t output_size = 0;
};

void mark_source_error(EncodeContext* context, int code, size_t x, size_t y,
                      size_t width, size_t height, size_t row,
                      size_t index = 0) noexcept {
  context->source_error.store(true, std::memory_order_relaxed);
  int expected = 0;
  if (context->source_error_code.compare_exchange_strong(
          expected, code, std::memory_order_relaxed)) {
    context->source_error_x = x;
    context->source_error_y = y;
    context->source_error_width = width;
    context->source_error_height = height;
    context->source_error_row = row;
    context->source_error_index = index;
  }
}

void mark_peak(EncodeContext* context, uint64_t value) noexcept {
  uint64_t peak = context->peak_chunk_bytes.load(std::memory_order_relaxed);
  while (value > peak && !context->peak_chunk_bytes.compare_exchange_weak(
                            peak, value, std::memory_order_relaxed)) {
  }
}

const uint8_t* fallback(EncodeContext* context, int code, size_t x = 0,
                        size_t y = 0, size_t width = 0, size_t height = 0,
                        size_t row = 0, size_t index = 0) noexcept {
  mark_source_error(context, code, x, y, width, height, row, index);
  return context->fallback.get();
}

uint8_t* allocate_chunk(EncodeContext* context, size_t bytes,
                        bool* limit_exceeded = nullptr) noexcept {
  if (bytes == 0 || bytes > kFallbackBytes ||
      bytes > std::numeric_limits<size_t>::max() - sizeof(uint64_t)) {
    return nullptr;
  }
  uint64_t active = context->active_chunk_bytes.load(std::memory_order_relaxed);
  for (;;) {
    if (active > context->active_chunk_limit_bytes ||
        bytes > context->active_chunk_limit_bytes - active) {
      if (limit_exceeded != nullptr) *limit_exceeded = true;
      return nullptr;
    }
    if (context->active_chunk_bytes.compare_exchange_weak(
            active, active + bytes, std::memory_order_relaxed))
      break;
  }
  auto* allocation = new (std::nothrow) uint8_t[sizeof(uint64_t) + bytes];
  if (allocation == nullptr) {
    context->active_chunk_bytes.fetch_sub(bytes, std::memory_order_relaxed);
    return nullptr;
  }
  std::memcpy(allocation, &bytes, sizeof(bytes));
  mark_peak(context, active + static_cast<uint64_t>(bytes));
  return allocation + sizeof(uint64_t);
}

void release_chunk(EncodeContext* context, const void* buffer) noexcept {
  if (buffer == nullptr || buffer == context->fallback.get()) return;
  auto* allocation = const_cast<uint8_t*>(static_cast<const uint8_t*>(buffer)) -
                     sizeof(uint64_t);
  uint64_t bytes = 0;
  std::memcpy(&bytes, allocation, sizeof(bytes));
  context->active_chunk_bytes.fetch_sub(bytes, std::memory_order_relaxed);
  delete[] allocation;
}

bool valid_rect(EncodeContext* context, size_t x, size_t y, size_t width,
                size_t height) noexcept {
  return width > 0 && height > 0 && width <= kMaxChunkDimension &&
         height <= kMaxChunkDimension &&
         x <= context->width && y <= context->height &&
         width <= static_cast<size_t>(context->width) - x &&
         height <= static_cast<size_t>(context->height) - y;
}

const void* get_color_pixels(void* opaque, size_t x, size_t y, size_t width,
                             size_t height, size_t* row_offset) noexcept {
  auto* context = static_cast<EncodeContext*>(opaque);
  const size_t stride = width * 3;
  if (row_offset != nullptr) *row_offset = stride;
  if (!valid_rect(context, x, y, width, height))
    return fallback(context, 1, x, y, width, height);
  const size_t bytes = stride * height;
  bool limit_exceeded = false;
  auto* output = allocate_chunk(context, bytes, &limit_exceeded);
  if (output == nullptr)
    return fallback(context, limit_exceeded ? 5 : 2, x, y, width, height);
  std::array<uint8_t, kMaxChunkDimension * 4u> row{};
  std::lock_guard<std::mutex> lock(context->input_mutex);
  for (size_t row_index = 0; row_index < height; ++row_index) {
    const uint64_t pixel = (static_cast<uint64_t>(y + row_index) * context->width) + x;
    const uint64_t offset = pixel * 4u;
    const size_t input_bytes = width * 4u;
    context->input.clear();
    context->input.seekg(static_cast<std::streamoff>(offset), std::ios::beg);
    context->input.read(reinterpret_cast<char*>(row.data()),
                        static_cast<std::streamsize>(input_bytes));
    if (context->input.gcount() != static_cast<std::streamsize>(input_bytes)) {
      mark_source_error(context, 3, x, y, width, height, row_index);
      std::memset(output + row_index * stride, 0, stride);
      continue;
    }
    uint8_t* destination = output + row_index * stride;
    for (size_t column = 0; column < width; ++column) {
      destination[column * 3] = row[column * 4];
      destination[column * 3 + 1] = row[column * 4 + 1];
      destination[column * 3 + 2] = row[column * 4 + 2];
    }
  }
  return output;
}

const void* get_alpha_pixels(void* opaque, size_t index, size_t x, size_t y,
                             size_t width, size_t height,
                             size_t* row_offset) noexcept {
  auto* context = static_cast<EncodeContext*>(opaque);
  const size_t stride = width;
  if (row_offset != nullptr) *row_offset = stride;
  if (index != 0)
    return fallback(context, 4, x, y, width, height, 0, index);
  if (!valid_rect(context, x, y, width, height))
    return fallback(context, 1, x, y, width, height, 0, index);
  const size_t bytes = stride * height;
  bool limit_exceeded = false;
  auto* output = allocate_chunk(context, bytes, &limit_exceeded);
  if (output == nullptr)
    return fallback(context, limit_exceeded ? 5 : 2, x, y, width, height, 0, index);
  std::array<uint8_t, kMaxChunkDimension * 4u> row{};
  std::lock_guard<std::mutex> lock(context->input_mutex);
  for (size_t row_index = 0; row_index < height; ++row_index) {
    const uint64_t pixel = (static_cast<uint64_t>(y + row_index) * context->width) + x;
    const uint64_t offset = pixel * 4u;
    const size_t input_bytes = width * 4u;
    context->input.clear();
    context->input.seekg(static_cast<std::streamoff>(offset), std::ios::beg);
    context->input.read(reinterpret_cast<char*>(row.data()),
                        static_cast<std::streamsize>(input_bytes));
    if (context->input.gcount() != static_cast<std::streamsize>(input_bytes)) {
      mark_source_error(context, 3, x, y, width, height, row_index, index);
      std::memset(output + row_index * stride, 0, stride);
      continue;
    }
    for (size_t column = 0; column < width; ++column)
      output[row_index * stride + column] = row[column * 4 + 3];
  }
  return output;
}

void get_color_format(void*, JxlPixelFormat* format) noexcept {
  if (format != nullptr) {
    format->num_channels = 3;
    format->data_type = JXL_TYPE_UINT8;
    format->endianness = JXL_NATIVE_ENDIAN;
    format->align = 0;
  }
}

void get_alpha_format(void*, size_t, JxlPixelFormat* format) noexcept {
  if (format != nullptr) {
    format->num_channels = 1;
    format->data_type = JXL_TYPE_UINT8;
    format->endianness = JXL_NATIVE_ENDIAN;
    format->align = 0;
  }
}

void release_pixels(void* opaque, const void* buffer) noexcept {
  release_chunk(static_cast<EncodeContext*>(opaque), buffer);
}

JxlParallelRetCode checkpoint_runner(void* runner_opaque, void* jpegxl_opaque,
                                     JxlParallelRunInit init,
                                     JxlParallelRunFunction function,
                                     uint32_t start, uint32_t end) noexcept {
  auto* context = static_cast<EncodeContext*>(runner_opaque);
  if (init(jpegxl_opaque, 1) != JXL_PARALLEL_RET_SUCCESS)
    return JXL_PARALLEL_RET_RUNNER_ERROR;
  for (uint32_t task = start; task < end; ++task) {
    if (context->checkpoint != nullptr &&
        context->checkpoint(context->checkpoint_opaque) == 0) {
      context->cancelled.store(true, std::memory_order_relaxed);
      return JXL_PARALLEL_RET_RUNNER_ERROR;
    }
    function(jpegxl_opaque, task, 0);
  }
  return JXL_PARALLEL_RET_SUCCESS;
}

void* output_get_buffer(void* opaque, size_t* size) noexcept {
  auto* context = static_cast<EncodeContext*>(opaque);
  if (size == nullptr) {
    context->output_error.store(true, std::memory_order_relaxed);
    return nullptr;
  }
  *size = std::min(std::max<size_t>(*size, 1), context->output_buffer.size());
  return context->output_buffer.data();
}

void output_release_buffer(void* opaque, size_t written) noexcept {
  auto* context = static_cast<EncodeContext*>(opaque);
  if (written > context->output_buffer.size()) {
    context->output_error.store(true, std::memory_order_relaxed);
    return;
  }
  std::lock_guard<std::mutex> lock(context->output_mutex);
  context->output.write(reinterpret_cast<const char*>(context->output_buffer.data()),
                        static_cast<std::streamsize>(written));
  if (!context->output) {
    context->output_error.store(true, std::memory_order_relaxed);
    return;
  }
  context->output_position += written;
  context->output_size = std::max(context->output_size, context->output_position);
}

void output_seek(void* opaque, uint64_t position) noexcept {
  auto* context = static_cast<EncodeContext*>(opaque);
  if (position > static_cast<uint64_t>(std::numeric_limits<std::streamoff>::max())) {
    context->output_error.store(true, std::memory_order_relaxed);
    return;
  }
  std::lock_guard<std::mutex> lock(context->output_mutex);
  context->output.seekp(static_cast<std::streamoff>(position), std::ios::beg);
  if (!context->output) {
    context->output_error.store(true, std::memory_order_relaxed);
    return;
  }
  context->output_position = position;
}

void output_finalize(void*, uint64_t) noexcept {}

bool status_ok(JxlEncoderStatus status, JxlEncoder* encoder) noexcept {
  return status == JXL_ENC_SUCCESS && encoder != nullptr &&
         JxlEncoderGetError(encoder) == JXL_ENC_ERR_OK;
}
}  // namespace

#if defined(LUMIA_JXL_TEST_HELPERS)
extern "C" int lumia_jxl_test_chunk_budget_probe(uint64_t* peak_bytes,
                                                 uint64_t* remaining_bytes) noexcept {
  EncodeContext context;
  constexpr size_t kProbeChunkBytes = kMaxChunk * 3u;
  std::array<const void*, 8> buffers{};
  size_t allocated = 0;
  for (; allocated < buffers.size(); ++allocated) {
    bool exceeded = false;
    buffers[allocated] = allocate_chunk(&context, kProbeChunkBytes, &exceeded);
    if (buffers[allocated] == nullptr) {
      if (!exceeded || allocated == 0) return 1;
      break;
    }
  }
  for (size_t index = 0; index < allocated; ++index)
    release_chunk(&context, buffers[index]);
  if (peak_bytes != nullptr)
    *peak_bytes = context.peak_chunk_bytes.load(std::memory_order_relaxed);
  if (remaining_bytes != nullptr)
    *remaining_bytes = context.active_chunk_bytes.load(std::memory_order_relaxed);
  return allocated < buffers.size() &&
                 context.active_chunk_bytes.load(std::memory_order_relaxed) == 0
             ? 0
             : 2;
}

extern "C" int lumia_jxl_test_read_rgba_pixel(
    const NativePathChar* input_path, uint32_t width, uint32_t height, uint32_t x,
    uint32_t y, uint8_t* rgba) noexcept {
  try {
    if (input_path == nullptr || rgba == nullptr || width == 0 || height == 0 ||
        x >= width || y >= height ||
        static_cast<uint64_t>(width) * height > 4'000'000'000ull)
      return 1;
    EncodeContext context;
    context.width = width;
    context.height = height;
    context.fallback.reset(new (std::nothrow) uint8_t[kFallbackBytes]());
    if (!context.fallback) return 2;
    context.input.open(std::filesystem::path(input_path), std::ios::binary);
    if (!context.input) return 3;
    const uint64_t expected_bytes = static_cast<uint64_t>(width) * height * 4u;
    context.input.seekg(0, std::ios::end);
    const std::streamoff size = context.input.tellg();
    if (size < 0 || static_cast<uint64_t>(size) != expected_bytes) return 4;
    context.input.clear();
    context.input.seekg(0, std::ios::beg);
    size_t color_stride = 0;
    size_t alpha_stride = 0;
    const void* color = get_color_pixels(&context, x, y, 1, 1, &color_stride);
    const void* alpha = get_alpha_pixels(&context, 0, x, y, 1, 1, &alpha_stride);
    if (context.source_error.load(std::memory_order_relaxed)) {
      release_pixels(&context, color);
      release_pixels(&context, alpha);
      return 5;
    }
    const auto* rgb = static_cast<const uint8_t*>(color);
    const auto* a = static_cast<const uint8_t*>(alpha);
    rgba[0] = rgb[0];
    rgba[1] = rgb[1];
    rgba[2] = rgb[2];
    rgba[3] = a[0];
    release_pixels(&context, color);
    release_pixels(&context, alpha);
    return 0;
  } catch (...) {
    return 6;
  }
}
#endif

extern "C" int lumia_jxl_encode_rgba_spool(
    const NativePathChar* input_path, const NativePathChar* output_path, uint32_t width,
    uint32_t height, uint64_t /*memory_budget_mib*/, CheckpointFn checkpoint,
    void* checkpoint_opaque, char* error_message, size_t error_capacity,
    uint64_t* peak_chunk_bytes) noexcept {
  try {
    if (input_path == nullptr || output_path == nullptr || width == 0 || height == 0 ||
        width > kMaxDimension || height > kMaxDimension ||
        (static_cast<uint64_t>(width) * height) > 4'000'000'000ull) {
      set_error(error_message, error_capacity, "invalid JPEG XL dimensions or path");
      return 2;
    }
    static_assert(sizeof(std::streamoff) >= 8,
                  "JPEG XL raw spool requires 64-bit file offsets");
    EncodeContext context;
    context.width = width;
    context.height = height;
    context.checkpoint = checkpoint;
    context.checkpoint_opaque = checkpoint_opaque;
    context.fallback.reset(new (std::nothrow) uint8_t[kFallbackBytes]());
    if (!context.fallback) {
      set_error(error_message, error_capacity, "could not allocate bounded fallback chunk");
      return 3;
    }
    context.input.open(std::filesystem::path(input_path), std::ios::binary);
    if (!context.input) {
      set_error(error_message, error_capacity, "could not open raw RGBA spool");
      return 4;
    }
    const uint64_t expected_bytes = static_cast<uint64_t>(width) * height * 4;
    context.input.seekg(0, std::ios::end);
    const std::streamoff spool_size = context.input.tellg();
    if (spool_size < 0 || static_cast<uint64_t>(spool_size) != expected_bytes) {
      set_error(error_message, error_capacity, "raw RGBA spool length does not match dimensions");
      return 5;
    }
    context.input.clear();
    context.input.seekg(0, std::ios::beg);
    context.output.open(std::filesystem::path(output_path),
                        std::ios::binary | std::ios::in | std::ios::out | std::ios::trunc);
    if (!context.output) {
      set_error(error_message, error_capacity, "could not open private JPEG XL output");
      return 6;
    }

    JxlEncoder* encoder = JxlEncoderCreate(nullptr);
    if (encoder == nullptr) {
      set_error(error_message, error_capacity, "could not allocate libjxl encoder");
      return 7;
    }
    int result = 0;
    JxlEncoderFrameSettings* settings = nullptr;
    auto fail = [&](const char* message, int code) {
      set_error(error_message, error_capacity, message);
      result = code;
    };

    if (JxlEncoderSetParallelRunner(encoder, checkpoint_runner, &context) != JXL_ENC_SUCCESS) {
      fail("could not install cancellable single-worker runner", 8);
    }
    if (result == 0 && JxlEncoderUseContainer(encoder, JXL_TRUE) != JXL_ENC_SUCCESS)
      fail("could not enable JPEG XL container", 9);

    JxlBasicInfo info;
    JxlEncoderInitBasicInfo(&info);
    info.xsize = width;
    info.ysize = height;
    info.bits_per_sample = 8;
    info.exponent_bits_per_sample = 0;
    info.num_color_channels = 3;
    info.num_extra_channels = 1;
    info.alpha_bits = 8;
    info.alpha_exponent_bits = 0;
    info.alpha_premultiplied = JXL_FALSE;
    info.uses_original_profile = JXL_TRUE;
    if (result == 0 && JxlEncoderSetBasicInfo(encoder, &info) != JXL_ENC_SUCCESS)
      fail("could not set JPEG XL image dimensions", 10);
    JxlColorEncoding color;
    JxlColorEncodingSetToSRGB(&color, JXL_FALSE);
    if (result == 0 && JxlEncoderSetColorEncoding(encoder, &color) != JXL_ENC_SUCCESS)
      fail("could not set JPEG XL sRGB color encoding", 11);

    JxlExtraChannelInfo alpha;
    JxlEncoderInitExtraChannelInfo(JXL_CHANNEL_ALPHA, &alpha);
    alpha.bits_per_sample = 8;
    alpha.alpha_premultiplied = JXL_FALSE;
    if (result == 0 &&
        JxlEncoderSetExtraChannelInfo(encoder, 0, &alpha) != JXL_ENC_SUCCESS)
      fail("could not define JPEG XL alpha channel", 12);

    if (result == 0) {
      settings = JxlEncoderFrameSettingsCreate(encoder, nullptr);
      if (settings == nullptr)
        fail("could not create JPEG XL frame settings", 13);
    }
    if (result == 0 &&
        JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_EFFORT, 3) !=
            JXL_ENC_SUCCESS)
      fail("could not set JPEG XL encoder effort 3", 14);
    if (result == 0 &&
        JxlEncoderFrameSettingsSetOption(settings,
                                         JXL_ENC_FRAME_SETTING_KEEP_INVISIBLE, 1) !=
            JXL_ENC_SUCCESS)
      fail("could not preserve RGB values below transparent pixels", 15);
    if (result == 0 &&
        JxlEncoderFrameSettingsSetOption(settings,
                                         JXL_ENC_FRAME_SETTING_OUTPUT_MODE, 1) !=
            JXL_ENC_SUCCESS)
      fail("could not enable seekable low-memory JXL output", 16);
    if (result == 0 && JxlEncoderSetFrameLossless(settings, JXL_TRUE) != JXL_ENC_SUCCESS)
      fail("could not enable lossless JPEG XL encoding", 17);

    JxlEncoderOutputProcessor output_processor{};
    output_processor.opaque = &context;
    output_processor.get_buffer = output_get_buffer;
    output_processor.release_buffer = output_release_buffer;
    output_processor.seek = output_seek;
    output_processor.set_finalized_position = output_finalize;
    if (result == 0 &&
        JxlEncoderSetOutputProcessor(encoder, output_processor) != JXL_ENC_SUCCESS)
      fail("could not configure seekable JPEG XL output", 18);

    JxlChunkedFrameInputSource source{};
    source.opaque = &context;
    source.get_color_channels_pixel_format = get_color_format;
    source.get_color_channel_data_at = get_color_pixels;
    source.get_extra_channel_pixel_format = get_alpha_format;
    source.get_extra_channel_data_at = get_alpha_pixels;
    source.release_buffer = release_pixels;
    if (result == 0 &&
        JxlEncoderAddChunkedFrame(settings, JXL_TRUE, source) != JXL_ENC_SUCCESS)
      fail("libjxl rejected the chunked RGBA frame", 19);
    while (result == 0) {
      const JxlEncoderStatus status = JxlEncoderFlushInput(encoder);
      if (status == JXL_ENC_SUCCESS) break;
      if (status == JXL_ENC_ERROR) {
        fail("libjxl failed while streaming JPEG XL output", 20);
        break;
      }
    }
    if (result == 0 && context.cancelled.load(std::memory_order_relaxed)) {
      set_error(error_message, error_capacity, "JPEG XL encoding cancelled");
      result = 1;
    }
    if (result == 0 && context.source_error.load(std::memory_order_relaxed)) {
      const int code = context.source_error_code.load(std::memory_order_relaxed);
      char detail[256]{};
      const char* kind = code == 1   ? "invalid callback rectangle"
                         : code == 2 ? "chunk allocation failed"
                         : code == 3 ? "short RGBA spool row read"
                         : code == 4 ? "unsupported extra-channel index"
                         : code == 5 ? "aggregate callback chunk limit exceeded"
                                     : "unknown chunk source failure";
      std::snprintf(detail, sizeof(detail),
                    "%s (code=%d, rect=%llu,%llu %llux%llu, row=%llu, index=%llu); output discarded",
                    kind, code,
                    static_cast<unsigned long long>(context.source_error_x),
                    static_cast<unsigned long long>(context.source_error_y),
                    static_cast<unsigned long long>(context.source_error_width),
                    static_cast<unsigned long long>(context.source_error_height),
                    static_cast<unsigned long long>(context.source_error_row),
                    static_cast<unsigned long long>(context.source_error_index));
      fail(detail, 21);
    }
    if (result == 0 && context.output_error.load(std::memory_order_relaxed))
      fail("JPEG XL output seek or write failed", 22);
    if (result == 0) {
      context.output.flush();
      if (!context.output) fail("could not flush JPEG XL output", 23);
      context.output.seekp(static_cast<std::streamoff>(context.output_size), std::ios::beg);
      if (!context.output) fail("could not finalize JPEG XL output length", 24);
      context.output.flush();
      if (!context.output) fail("could not finalize JPEG XL output", 25);
    }
    if (peak_chunk_bytes != nullptr)
      *peak_chunk_bytes = context.peak_chunk_bytes.load(std::memory_order_relaxed);
    if (settings != nullptr) {
      // Frame settings are owned by the encoder and released with it.
      settings = nullptr;
    }
    JxlEncoderDestroy(encoder);
    return result;
  } catch (const std::exception& error) {
    set_error(error_message, error_capacity, error.what());
    return 26;
  } catch (...) {
    set_error(error_message, error_capacity, "unknown native JPEG XL bridge failure");
    return 27;
  }
}
