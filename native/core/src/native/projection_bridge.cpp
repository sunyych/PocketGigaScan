#include <opencv2/calib3d.hpp>
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>

extern "C" {
struct LgLensCalibration {
  int32_t has_horizontal_fov;
  double horizontal_fov_deg;
  int32_t has_vertical_fov;
  double vertical_fov_deg;
  int32_t has_distortion;
  double k1;
  double k2;
  double p1;
  double p2;
  double k3;
  int32_t has_principal_point;
  double principal_x;
  double principal_y;
};
}

namespace {
constexpr int kPlanar = 0;
constexpr int kCylindrical = 1;
constexpr int kSpherical = 2;
constexpr double kDefaultHorizontalFov = 82.0;
constexpr double kDefaultVerticalFov = 52.0;

bool finite(double value) { return std::isfinite(value); }
bool valid_fov(double value) { return finite(value) && value > 0.0 && value < 180.0; }
bool valid_dimensions(int width, int height) {
  return width > 0 && height > 0 &&
         static_cast<uint64_t>(width) * static_cast<uint64_t>(height) <=
             static_cast<uint64_t>(std::numeric_limits<std::size_t>::max() / 4);
}

bool valid_calibration(const LgLensCalibration* calibration) {
  if (!calibration) return true;
  if (calibration->has_horizontal_fov && !valid_fov(calibration->horizontal_fov_deg)) return false;
  if (calibration->has_vertical_fov && !valid_fov(calibration->vertical_fov_deg)) return false;
  if (calibration->has_principal_point &&
      (!finite(calibration->principal_x) || !finite(calibration->principal_y) ||
       calibration->principal_x < 0.0 || calibration->principal_x > 1.0 ||
       calibration->principal_y < 0.0 || calibration->principal_y > 1.0)) return false;
  if (calibration->has_distortion) {
    if (!finite(calibration->k1) || !finite(calibration->k2) ||
        !finite(calibration->p1) || !finite(calibration->p2) || !finite(calibration->k3)) return false;
  }
  return true;
}

double fov_or(const LgLensCalibration* calibration, bool horizontal, double fallback) {
  if (!calibration) return fallback;
  if (horizontal && calibration->has_horizontal_fov) return calibration->horizontal_fov_deg;
  if (!horizontal && calibration->has_vertical_fov) return calibration->vertical_fov_deg;
  return fallback;
}

void principal_or(const LgLensCalibration* calibration, int width, int height,
                  double* cx, double* cy) {
  if (calibration && calibration->has_principal_point) {
    *cx = static_cast<double>(width) * calibration->principal_x;
    *cy = static_cast<double>(height) * calibration->principal_y;
  } else {
    // _undistort uses source.cols/source.rows times the normalized default
    // principal point (0.5), rather than the (width - 1) / 2 warp center.
    *cx = static_cast<double>(width) * 0.5;
    *cy = static_cast<double>(height) * 0.5;
  }
}

bool has_distortion(const LgLensCalibration* calibration) {
  if (!calibration || !calibration->has_distortion) return false;
  return std::abs(calibration->k1) > 1e-12 || std::abs(calibration->k2) > 1e-12 ||
         std::abs(calibration->p1) > 1e-12 || std::abs(calibration->p2) > 1e-12 ||
         std::abs(calibration->k3) > 1e-12;
}

// Build the same inverse maps as _cylindricalWarp/_sphericalWarp in the Dart
// engine.  OpenCV remap owns interpolation and constant-border behavior.
void make_projection_maps(int width, int height, int projection,
                          const LgLensCalibration* calibration,
                          cv::Mat* map_x, cv::Mat* map_y) {
  map_x->create(height, width, CV_32FC1);
  map_y->create(height, width, CV_32FC1);
  const double fov_x = fov_or(calibration, true, kDefaultHorizontalFov) * CV_PI / 180.0;
  const double fov_y = fov_or(calibration, false, kDefaultVerticalFov) * CV_PI / 180.0;
  const double fx = static_cast<double>(width) / (2.0 * std::tan(fov_x / 2.0));
  const double fy = projection == kSpherical
      ? static_cast<double>(height) / (2.0 * std::tan(fov_y / 2.0))
      : fx;
  const double cx = static_cast<double>(width - 1) / 2.0;
  const double cy = static_cast<double>(height - 1) / 2.0;
  for (int y = 0; y < height; ++y) {
    const double v = (static_cast<double>(y) - cy) / fy;
    const double tan_v = std::tan(v);
    for (int x = 0; x < width; ++x) {
      const double theta = (static_cast<double>(x) - cx) / fx;
      const double cos_theta = std::cos(theta);
      float source_x = static_cast<float>(fx * std::tan(theta) + cx);
      float source_y;
      if (projection == kCylindrical) {
        source_y = static_cast<float>(fy * v / cos_theta + cy);
      } else {
        source_y = static_cast<float>(fy * tan_v / cos_theta + cy);
      }
      map_x->at<float>(y, x) = source_x;
      map_y->at<float>(y, x) = source_y;
    }
  }
}

bool build_lens_maps(int width, int height, const LgLensCalibration* calibration,
                     cv::Mat* map_x, cv::Mat* map_y) {
  if (!has_distortion(calibration)) return false;
  double cx = 0.0, cy = 0.0;
  principal_or(calibration, width, height, &cx, &cy);
  const double fov_x = fov_or(calibration, true, kDefaultHorizontalFov) * CV_PI / 180.0;
  const double fx = static_cast<double>(width) / (2.0 * std::tan(fov_x / 2.0));
  cv::Mat camera = (cv::Mat_<double>(3, 3) << fx, 0.0, cx, 0.0, fx, cy, 0.0, 0.0, 1.0);
  cv::Mat distortion = (cv::Mat_<double>(1, 5) << calibration->k1, calibration->k2,
                       calibration->p1, calibration->p2, calibration->k3);
  cv::initUndistortRectifyMap(camera, distortion, cv::Mat(), camera,
                              cv::Size(width, height), CV_32FC1, *map_x, *map_y);
  return true;
}
}

// Return 0 on success.  Negative values indicate invalid arguments or an
// OpenCV/exception failure; no exception is allowed to cross the C ABI.
extern "C" int lg_projection_apply_rgb(
    const uint8_t* source_rgb, std::size_t source_len, int width, int height,
    int projection, const LgLensCalibration* calibration,
    uint8_t* output_rgba, std::size_t output_len) {
  try {
    if (!source_rgb || !output_rgba || !valid_dimensions(width, height) ||
        source_len != static_cast<std::size_t>(width) * static_cast<std::size_t>(height) * 3 ||
        output_len != static_cast<std::size_t>(width) * static_cast<std::size_t>(height) * 4 ||
        (projection != kPlanar && projection != kCylindrical && projection != kSpherical) ||
        !valid_calibration(calibration)) return -1;

    const cv::Mat source(height, width, CV_8UC3,
                         const_cast<uint8_t*>(source_rgb));
    cv::Mat corrected;
    cv::Mat valid_source(height, width, CV_8UC1, cv::Scalar(255));
    cv::Mat corrected_valid;
    cv::Mat lens_x, lens_y;
    if (build_lens_maps(width, height, calibration, &lens_x, &lens_y)) {
      cv::remap(source, corrected, lens_x, lens_y, cv::INTER_LINEAR,
                cv::BORDER_CONSTANT, cv::Scalar(0, 0, 0));
      cv::remap(valid_source, corrected_valid, lens_x, lens_y, cv::INTER_LINEAR,
                cv::BORDER_CONSTANT, cv::Scalar(0));
    } else {
      corrected = source;
      corrected_valid = valid_source;
    }

    cv::Mat projected;
    cv::Mat projected_valid;
    cv::Mat projection_x, projection_y;
    if (projection != kPlanar) {
      make_projection_maps(width, height, projection, calibration, &projection_x, &projection_y);
      cv::remap(corrected, projected, projection_x, projection_y, cv::INTER_LINEAR,
                cv::BORDER_CONSTANT, cv::Scalar(0, 0, 0));
      cv::remap(corrected_valid, projected_valid, projection_x, projection_y, cv::INTER_LINEAR,
                cv::BORDER_CONSTANT, cv::Scalar(0));
    } else {
      projected = corrected;
      projected_valid = corrected_valid;
    }

    for (int y = 0; y < height; ++y) {
      const auto* rgb = projected.ptr<cv::Vec3b>(y);
      const auto* mask = projected_valid.ptr<uint8_t>(y);
      auto* rgba = output_rgba + static_cast<std::size_t>(y) * static_cast<std::size_t>(width) * 4;
      for (int x = 0; x < width; ++x) {
        const std::size_t out = static_cast<std::size_t>(x) * 4;
        // The input and output contract is RGB/RGBA, while cv::Mat stores the
        // three channels without changing their byte order here.
        rgba[out] = rgb[x][0];
        rgba[out + 1] = rgb[x][1];
        rgba[out + 2] = rgb[x][2];
        rgba[out + 3] = mask[x];
      }
    }
    return 0;
  } catch (const cv::Exception&) {
    return -2;
  } catch (...) {
    return -3;
  }
}
