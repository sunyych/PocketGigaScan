package com.opencapture.openpocketcine.gigascan

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
}
