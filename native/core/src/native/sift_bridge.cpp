#include <opencv2/calib3d.hpp>
#include <opencv2/features2d.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/core/utility.hpp>
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <exception>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <vector>

namespace {
// Descriptor matching reads immutable FeatureFrame data. A shared mutex lets
// independent edges match concurrently while extraction and process-global
// OpenCV thread-count changes remain exclusive.
std::shared_mutex opencv_feature_mutex;
bool opencv_threads_frozen = false;

struct FeatureBatchGuard {
  int previous_threads;
  std::unique_lock<std::shared_mutex> lock;
  FeatureBatchGuard() : previous_threads(0), lock(opencv_feature_mutex) {
    previous_threads = cv::getNumThreads();
    cv::setNumThreads(1);
    opencv_threads_frozen = true;
  }
  ~FeatureBatchGuard() {
    cv::setNumThreads(previous_threads);
    opencv_threads_frozen = false;
  }
};

struct FeatureFrame {
  std::vector<cv::KeyPoint> keypoints;
  cv::Mat descriptors;
  int count = 0;
  double threshold_scale = 1.0;
  bool orb = false;
};
double median(std::vector<double> values) {
  if (values.empty()) return 0.0;
  std::sort(values.begin(), values.end());
  return values[values.size() / 2];
}
void clear_outputs(double* homography, double* dx, double* dy, double* ratio, double* residual,
                   int* matches, int* inliers, int* reason) {
  if (homography) {
    for (int i = 0; i < 9; ++i) homography[i] = (i % 4 == 0) ? 1.0 : 0.0;
  }
  if (dx) *dx = 0.0;
  if (dy) *dy = 0.0;
  if (ratio) *ratio = 0.0;
  if (residual) *residual = 0.0;
  if (matches) *matches = 0;
  if (inliers) *inliers = 0;
  if (reason) *reason = 0;
}
}

namespace {
void* create_features(const char* path, int* feature_count, double maximum_pixels,
                      int thread_limit = 0, double contrast_threshold = 0.015,
                      bool apply_clahe = false, bool batch_worker = false,
                      bool use_orb = false) {
  if (feature_count) *feature_count = 0;
  try {
    if (!path) return nullptr;
    // OpenCV's thread count is process-global. Keep SIFT extraction and its
    // temporary thread-limit change isolated from concurrent matcher calls.
    std::unique_lock<std::shared_mutex> opencv_lock;
    if (!batch_worker) opencv_lock = std::unique_lock<std::shared_mutex>(opencv_feature_mutex);
    const cv::Mat image = cv::imread(path, cv::IMREAD_GRAYSCALE);
    if (image.empty()) return nullptr;
    auto frame = std::make_unique<FeatureFrame>();
    frame->orb = use_orb;
    cv::Mat working = image;
    const double area = static_cast<double>(image.cols) * image.rows;
    if (area > maximum_pixels) {
      const double scale = std::sqrt(maximum_pixels / area);
      cv::resize(image, working, cv::Size(), scale, scale, cv::INTER_AREA);
      frame->threshold_scale = 1.0 / scale;
    }
    if (apply_clahe) {
      cv::Mat enhanced;
      cv::createCLAHE(2.0, cv::Size(8, 8))->apply(working, enhanced);
      working = enhanced;
    }
    struct ThreadLimit {
      int previous;
      bool active;
      explicit ThreadLimit(int requested, bool frozen)
          : previous(requested > 0 && !frozen ? cv::getNumThreads() : 0), active(requested > 0 && !frozen) {
        if (active) cv::setNumThreads(requested);
      }
      ~ThreadLimit() { if (active) cv::setNumThreads(previous); }
    } limit(thread_limit, opencv_threads_frozen);
    if (use_orb) {
      cv::ORB::create(2500)->detectAndCompute(working, cv::noArray(), frame->keypoints, frame->descriptors);
    } else {
      cv::SIFT::create(2500, 3, contrast_threshold, 16)->detectAndCompute(
          working, cv::noArray(), frame->keypoints, frame->descriptors);
    }
    if (frame->threshold_scale != 1.0) {
      for (auto& keypoint : frame->keypoints) keypoint.pt *= static_cast<float>(frame->threshold_scale);
    }
    frame->count = static_cast<int>(frame->keypoints.size());
    if (feature_count) *feature_count = frame->count;
    return frame.release();
  } catch (...) { return nullptr; }
}
}
extern "C" void* lg_sift_batch_begin() {
  try {
    return new FeatureBatchGuard();
  } catch (...) { return nullptr; }
}
extern "C" void lg_sift_batch_end(void* guard) {
  try { delete static_cast<FeatureBatchGuard*>(guard); } catch (...) {}
}
extern "C" void* lg_sift_features_create_batch(const char* path, int* feature_count,
                                                   std::size_t maximum_pixels,
                                                   double contrast_threshold,
                                                   void* guard, int use_orb) {
  if (!guard || maximum_pixels == 0 || !std::isfinite(contrast_threshold) ||
      contrast_threshold <= 0.0 || contrast_threshold > 1.0) return nullptr;
  return create_features(path, feature_count, static_cast<double>(maximum_pixels), 1,
                         contrast_threshold, false, true, use_orb != 0);
}
extern "C" void* lg_sift_features_create_contrast_batch(const char* path, int* feature_count,
                                                            std::size_t maximum_pixels,
                                                            double contrast_threshold,
                                                            void* guard, int use_orb) {
  if (!guard || maximum_pixels == 0 || !std::isfinite(contrast_threshold) ||
      contrast_threshold <= 0.0 || contrast_threshold > 1.0) return nullptr;
  return create_features(path, feature_count, static_cast<double>(maximum_pixels), 1,
                         contrast_threshold, false, true, use_orb != 0);
}
extern "C" void* lg_sift_features_create_clahe_batch(const char* path, int* feature_count,
                                                         std::size_t maximum_pixels,
                                                         double contrast_threshold,
                                                         void* guard, int use_orb) {
  if (!guard || maximum_pixels == 0 || !std::isfinite(contrast_threshold) ||
      contrast_threshold <= 0.0 || contrast_threshold > 1.0) return nullptr;
  return create_features(path, feature_count, static_cast<double>(maximum_pixels), 1,
                         contrast_threshold, true, true, use_orb != 0);
}
extern "C" void* lg_sift_features_create(const char* path, int* feature_count) {
  return create_features(path, feature_count, 120000.0);
}
extern "C" void* lg_sift_features_create_bounded(const char* path, int* feature_count,
                                                    std::size_t maximum_pixels,
                                                    int thread_limit) {
  if (maximum_pixels == 0 || thread_limit < 0 || thread_limit > 8) return nullptr;
  return create_features(path, feature_count, static_cast<double>(maximum_pixels), thread_limit);
}
extern "C" void* lg_sift_features_create_bounded_contrast(const char* path, int* feature_count,
                                                            std::size_t maximum_pixels,
                                                            int thread_limit,
                                                            double contrast_threshold, int use_orb) {
  if (maximum_pixels == 0 || thread_limit < 0 || thread_limit > 8 ||
      !std::isfinite(contrast_threshold) || contrast_threshold <= 0.0 || contrast_threshold > 1.0)
    return nullptr;
  return create_features(path, feature_count, static_cast<double>(maximum_pixels), thread_limit,
                         contrast_threshold, false, false, use_orb != 0);
}
extern "C" void* lg_sift_features_create_bounded_clahe(const char* path, int* feature_count,
                                                          std::size_t maximum_pixels,
                                                          int thread_limit,
                                                          double contrast_threshold, int use_orb) {
  if (maximum_pixels == 0 || thread_limit < 0 || thread_limit > 8 ||
      !std::isfinite(contrast_threshold) || contrast_threshold <= 0.0 || contrast_threshold > 1.0)
    return nullptr;
  return create_features(path, feature_count, static_cast<double>(maximum_pixels), thread_limit,
                         contrast_threshold, true, false, use_orb != 0);
}
extern "C" void lg_sift_features_destroy(void* opaque) {
  try { delete static_cast<FeatureFrame*>(opaque); } catch (...) {}
}
extern "C" int lg_sift_features_count(const void* opaque) {
  if (!opaque) return 0;
  try { return static_cast<const FeatureFrame*>(opaque)->count; } catch (...) { return 0; }
}

// Return value means a homography was computed. Rust applies acceptance gates.
// reason: 1 no descriptors, 2 too few mutual ratio matches, 3 RANSAC failed.
extern "C" int lg_sift_match(const void* from_opaque, const void* to_opaque,
                              double expected_dx, double expected_dy, double width,
                              double height, double* homography_out,
                              double* dx, double* dy,
                              double* inlier_ratio, double* median_residual,
                              int* matches, int* inliers, int* reason) {
  clear_outputs(homography_out, dx, dy, inlier_ratio, median_residual, matches, inliers, reason);
  try {
    std::shared_lock<std::shared_mutex> opencv_lock(opencv_feature_mutex);
    if (!from_opaque || !to_opaque) { if (reason) *reason = 1; return 0; }
    const auto& from = *static_cast<const FeatureFrame*>(from_opaque);
    const auto& to = *static_cast<const FeatureFrame*>(to_opaque);
    if (from.descriptors.empty() || to.descriptors.empty()) { if (reason) *reason = 1; return 0; }
    const cv::BFMatcher matcher(cv::NORM_L2);
    std::vector<std::vector<cv::DMatch>> forward, backward;
    matcher.knnMatch(from.descriptors, to.descriptors, forward, 2);
    matcher.knnMatch(to.descriptors, from.descriptors, backward, 2);
    std::vector<int> reverse(backward.size(), -1);
    for (std::size_t i = 0; i < backward.size(); ++i) {
      const auto& c = backward[i];
      if (c.size() >= 2 && c[0].distance < 0.78f * c[1].distance) reverse[i] = c[0].trainIdx;
    }
    std::vector<cv::Point2f> source, target;
    for (const auto& c : forward) {
      if (c.size() < 2 || c[0].distance >= 0.78f * c[1].distance) continue;
      const auto& best = c[0];
      if (best.trainIdx < 0 || static_cast<std::size_t>(best.trainIdx) >= reverse.size() || reverse[best.trainIdx] != best.queryIdx) continue;
      source.push_back(from.keypoints[best.queryIdx].pt);
      target.push_back(to.keypoints[best.trainIdx].pt);
    }
    if (matches) *matches = static_cast<int>(source.size());
    if (source.size() < 12) { if (reason) *reason = 2; return 0; }
    cv::Mat mask;
    const double reprojection_threshold = 3.0 * std::max(from.threshold_scale, to.threshold_scale);
    const cv::Mat homography = cv::findHomography(source, target, cv::RANSAC, reprojection_threshold, mask, 4000, 0.997);
    if (homography.empty()) { if (reason) *reason = 3; return 0; }
    const double normalization = homography.at<double>(2, 2);
    if (!std::isfinite(normalization) || std::abs(normalization) < 1e-12) {
      if (reason) *reason = 3;
      return 0;
    }
    if (homography_out) {
      for (int row = 0; row < 3; ++row) {
        for (int column = 0; column < 3; ++column) {
          homography_out[row * 3 + column] =
              homography.at<double>(row, column) / normalization;
        }
      }
    }
    std::vector<double> xs, ys, residuals;
    for (std::size_t i = 0; i < source.size(); ++i) {
      if (i >= mask.total() || mask.at<unsigned char>(static_cast<int>(i)) == 0) continue;
      const double px = source[i].x, py = source[i].y;
      const double denominator = homography.at<double>(2, 0) * px + homography.at<double>(2, 1) * py + homography.at<double>(2, 2);
      if (std::abs(denominator) < 1e-9) continue;
      const double projected_x = (homography.at<double>(0, 0) * px + homography.at<double>(0, 1) * py + homography.at<double>(0, 2)) / denominator;
      const double projected_y = (homography.at<double>(1, 0) * px + homography.at<double>(1, 1) * py + homography.at<double>(1, 2)) / denominator;
      xs.push_back(target[i].x - source[i].x);
      ys.push_back(target[i].y - source[i].y);
      residuals.push_back(std::hypot(projected_x - target[i].x, projected_y - target[i].y));
    }
    if (inliers) *inliers = static_cast<int>(residuals.size());
    if (residuals.empty()) { if (reason) *reason = 3; return 0; }
    if (dx) *dx = median(xs);
    if (dy) *dy = median(ys);
    if (inlier_ratio) *inlier_ratio = static_cast<double>(residuals.size()) / static_cast<double>(source.size());
    if (median_residual) *median_residual = median(residuals);
    (void)expected_dx; (void)expected_dy; (void)width; (void)height;
    return 1;
  } catch (...) { if (reason) *reason = 3; return 0; }
}

// Rotation-first registration uses the RANSAC inlier rays directly. The
// planar homography above remains useful diagnostics but is not the pose.
extern "C" int lg_sift_match_points(const void* from_opaque, const void* to_opaque,
                                     double* source_xy, double* target_xy,
                                     int capacity, int* matches, int* inliers,
                                     double* inlier_ratio, double* median_residual,
                                     int* reason, int use_flann, void* guard) {
  if (matches) *matches = 0;
  if (inliers) *inliers = 0;
  if (inlier_ratio) *inlier_ratio = 0.0;
  if (median_residual) *median_residual = 0.0;
  if (reason) *reason = 0;
  try {
    std::shared_lock<std::shared_mutex> opencv_lock;
    if (!guard) opencv_lock = std::shared_lock<std::shared_mutex>(opencv_feature_mutex);
    if (!from_opaque || !to_opaque || capacity <= 0 || !source_xy || !target_xy) {
      if (reason) *reason = 1;
      return 0;
    }
    const auto& from = *static_cast<const FeatureFrame*>(from_opaque);
    const auto& to = *static_cast<const FeatureFrame*>(to_opaque);
    if (from.orb != to.orb || (from.orb && use_flann)) { if (reason) *reason = 1; return 0; }
    if (from.descriptors.empty() || to.descriptors.empty()) {
      if (reason) *reason = 1;
      return 0;
    }
    std::vector<std::vector<cv::DMatch>> forward, backward;
    if (use_flann) {
      cv::FlannBasedMatcher matcher;
      matcher.knnMatch(from.descriptors, to.descriptors, forward, 2);
      matcher.knnMatch(to.descriptors, from.descriptors, backward, 2);
    } else {
      cv::BFMatcher matcher(from.orb ? cv::NORM_HAMMING : cv::NORM_L2);
      matcher.knnMatch(from.descriptors, to.descriptors, forward, 2);
      matcher.knnMatch(to.descriptors, from.descriptors, backward, 2);
    }
    std::vector<int> reverse(backward.size(), -1);
    for (std::size_t i = 0; i < backward.size(); ++i) {
      const auto& candidates = backward[i];
      if (candidates.size() >= 2 && candidates[0].distance < 0.78f * candidates[1].distance)
        reverse[i] = candidates[0].trainIdx;
    }
    std::vector<cv::Point2f> source, target;
    for (const auto& candidates : forward) {
      if (candidates.size() < 2 || candidates[0].distance >= 0.78f * candidates[1].distance) continue;
      const auto& best = candidates[0];
      if (best.trainIdx < 0 || static_cast<std::size_t>(best.trainIdx) >= reverse.size() ||
          reverse[best.trainIdx] != best.queryIdx) continue;
      source.push_back(from.keypoints[best.queryIdx].pt);
      target.push_back(to.keypoints[best.trainIdx].pt);
    }
    if (matches) *matches = static_cast<int>(source.size());
    if (source.size() < 12) { if (reason) *reason = 2; return 0; }
    cv::Mat mask;
    const double threshold = 3.0 * std::max(from.threshold_scale, to.threshold_scale);
    const cv::Mat h = cv::findHomography(source, target, cv::RANSAC, threshold, mask, 4000, 0.997);
    if (h.empty()) { if (reason) *reason = 3; return 0; }
    const double norm = h.at<double>(2, 2);
    if (!std::isfinite(norm) || std::abs(norm) < 1e-12) { if (reason) *reason = 3; return 0; }
    std::vector<double> residuals;
    int output_count = 0;
    for (std::size_t i = 0; i < source.size(); ++i) {
      if (i >= mask.total() || mask.at<unsigned char>(static_cast<int>(i)) == 0) continue;
      if (output_count >= capacity) break;
      const double x = source[i].x, y = source[i].y;
      const double d = h.at<double>(2,0)*x + h.at<double>(2,1)*y + h.at<double>(2,2);
      if (!std::isfinite(d) || std::abs(d) < 1e-9) continue;
      const double px = (h.at<double>(0,0)*x + h.at<double>(0,1)*y + h.at<double>(0,2)) / d;
      const double py = (h.at<double>(1,0)*x + h.at<double>(1,1)*y + h.at<double>(1,2)) / d;
      source_xy[2*output_count] = x; source_xy[2*output_count+1] = y;
      target_xy[2*output_count] = target[i].x; target_xy[2*output_count+1] = target[i].y;
      residuals.push_back(std::hypot(px-target[i].x, py-target[i].y));
      ++output_count;
    }
    if (output_count < 8) { if (reason) *reason = 3; return 0; }
    if (inliers) *inliers = output_count;
    if (inlier_ratio) *inlier_ratio = static_cast<double>(output_count) / static_cast<double>(source.size());
    if (median_residual) *median_residual = median(residuals);
    return 1;
  } catch (...) { if (reason) *reason = 3; return 0; }
}
