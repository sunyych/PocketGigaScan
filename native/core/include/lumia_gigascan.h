#ifndef LUMIA_GIGASCAN_H
#define LUMIA_GIGASCAN_H

#include <stdint.h>

#if defined(_WIN32)
#define LUMIA_GIGASCAN_EXPORT __declspec(dllimport)
#else
#define LUMIA_GIGASCAN_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*lumia_gigascan_progress_callback)(
    const char* stage,
    float fraction,
    void* user_data);

LUMIA_GIGASCAN_EXPORT uint32_t lumia_gigascan_abi_version(void);
LUMIA_GIGASCAN_EXPORT uint32_t lumia_gigascan_is_available(void);

LUMIA_GIGASCAN_EXPORT char* lumia_gigascan_stitch_json(
    const char* request,
    lumia_gigascan_progress_callback callback,
    void* user_data);

/* Alignment only; same request as stitch, outputPath optional and ignored. */
LUMIA_GIGASCAN_EXPORT char* lumia_gigascan_register_json(const char* request);

/* Visual registration and globally optimized camera-to-world rotations. */
LUMIA_GIGASCAN_EXPORT char* lumia_gigascan_spherical_json(const char* request);

/* Asynchronous persistent tiled spherical render jobs. */
LUMIA_GIGASCAN_EXPORT char* lumia_gigascan_job_json(const char* request);

LUMIA_GIGASCAN_EXPORT char* lumia_gigascan_plan_json(const char* request);

LUMIA_GIGASCAN_EXPORT void lumia_gigascan_free(char* value);
LUMIA_GIGASCAN_EXPORT void lumia_gigascan_free_json(char* value);

#ifdef __cplusplus
}
#endif

#endif
