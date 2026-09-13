package com.opencapture.openpocketcine.gigascan

import org.json.JSONObject

/**
 * Thin JSON/JNI consumer for the independent lumia-gigascan-core artifact.
 * Camera transport, capture, jobs, and UI remain in the Android shell.
 */
object LumiaGigaScanCoreBridge {
    const val SUPPORTED_ABI_VERSION = 1

    private val jniLoaded: Boolean by lazy {
        try {
            System.loadLibrary("lumia_gigascan_jni")
            true
        } catch (_: UnsatisfiedLinkError) {
            false
        }
    }

    val isAvailable: Boolean
        get() = jniLoaded && nativeIsAvailable()

    fun plan(request: JSONObject): JSONObject {
        checkAvailable()
        return parseResponse(nativePlanJson(request.toString()))
    }

    fun stitch(request: JSONObject): JSONObject {
        checkAvailable()
        return parseResponse(nativeStitchJson(withMobileRenderPreference(request).toString()))
    }

    internal fun withMobileRenderPreference(request: JSONObject): JSONObject {
        val preferred = JSONObject(request.toString())
        if (!preferred.has("renderBackendPreference")) {
            preferred.put("renderBackendPreference", "gpuPreferred")
        }
        return preferred
    }

    private fun checkAvailable() {
        check(isAvailable) { "lumia-gigascan-core is not built or bundled" }
        val actual = nativeAbiVersion()
        check(actual == SUPPORTED_ABI_VERSION) {
            "lumia-gigascan-core ABI $actual is incompatible with $SUPPORTED_ABI_VERSION"
        }
    }

    private fun parseResponse(response: String?): JSONObject {
        checkNotNull(response) { "lumia-gigascan-core returned a null response" }
        return JSONObject(response)
    }

    private external fun nativeIsAvailable(): Boolean
    private external fun nativeAbiVersion(): Int
    private external fun nativePlanJson(request: String): String?
    private external fun nativeStitchJson(request: String): String?
}

object LumiaGigaScanPlanRequest {
    fun explicitThreeByThree(
        estimatedBytesPerTile: Long = 10L,
        maximumTiles: Int = 4096,
    ): JSONObject {
        val fov =
            JSONObject()
                .put("horizontal", 82.0)
                .put("vertical", 52.0)
                .put("mechanicalPan", 260.0)
                .put("mechanicalTilt", 130.0)
        return JSONObject()
            .put(
                "source",
                JSONObject()
                    .put("pan", 0.0)
                    .put("tilt", 0.0)
                    .put("zoom", 1.0),
            )
            .put("sourceFov", fov)
            .put(
                "roi",
                JSONObject()
                    .put("left", 0.1)
                    .put("top", 0.1)
                    .put("right", 0.9)
                    .put("bottom", 0.9),
            )
            .put("targetFov", JSONObject(fov.toString()))
            .put("overlapX", 0.3)
            .put("overlapY", 0.3)
            .put(
                "grid",
                JSONObject()
                    .put("mode", "explicit")
                    .put("rows", 3)
                    .put("columns", 3),
            )
            .put("traversal", "rowByRow")
            .put("estimatedBytesPerTile", estimatedBytesPerTile)
            .put("maximumTiles", maximumTiles)
    }
}
