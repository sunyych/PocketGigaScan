package com.opencapture.openpocketcine.gigascan

import org.json.JSONObject
import kotlin.test.Test
import kotlin.test.assertEquals

class LumiaGigaScanCoreBridgeTest {
    @Test
    fun explicitThreeByThreeRequestMatchesCoreAbi() {
        val request = LumiaGigaScanPlanRequest.explicitThreeByThree()
        val grid = request.getJSONObject("grid")

        assertEquals("explicit", grid.getString("mode"))
        assertEquals(3, grid.getInt("rows"))
        assertEquals(3, grid.getInt("columns"))
        assertEquals("rowByRow", request.getString("traversal"))
        assertEquals(9, grid.getInt("rows") * grid.getInt("columns"))
    }

    @Test
    fun mobileStitchDefaultsToGpuAndPreservesExplicitCpuChoice() {
        val preferred =
            LumiaGigaScanCoreBridge.withMobileRenderPreference(JSONObject().put("rows", 5))
        assertEquals("gpuPreferred", preferred.getString("renderBackendPreference"))

        val cpuOnly =
            LumiaGigaScanCoreBridge.withMobileRenderPreference(
                JSONObject().put("renderBackendPreference", "cpuOnly"),
            )
        assertEquals("cpuOnly", cpuOnly.getString("renderBackendPreference"))
    }
}
