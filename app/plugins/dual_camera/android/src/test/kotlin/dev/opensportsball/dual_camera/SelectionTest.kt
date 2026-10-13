// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

package dev.opensportsball.dual_camera

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

internal class SelectionTest {
    @Test
    fun segmentFileNamesArePaddedToThree() {
        assertEquals("abc_000.mp4", Selection.segmentFileName("abc", 0))
        assertEquals("abc_042.mp4", Selection.segmentFileName("abc", 42))
        assertEquals("abc_1234.mp4", Selection.segmentFileName("abc", 1234))
    }

    @Test
    fun upInDisplayFollowsTheScreen() {
        // Held upright in portrait: up is the top of the screen at rotation 0.
        assertEquals(listOf(0f, 9.8f, 0f), Selection.upInDisplay(0f, 9.8f, 0f, 0).toList())
        // Turned counterclockwise into landscape (rotation 90): the device's
        // right edge is now the top of the screen.
        assertEquals(listOf(-0f, 9.8f, 1f), Selection.upInDisplay(9.8f, 0f, 1f, 90).toList())
        // The same landscape interface on a phone turned the other way up:
        // up is the bottom of the picture.
        assertEquals(listOf(-0f, -9.8f, 1f), Selection.upInDisplay(-9.8f, 0f, 1f, 90).toList())
        assertEquals(listOf(0f, 9.8f, 0f), Selection.upInDisplay(-9.8f, 0f, 0f, 270).toList())
        assertEquals(listOf(-0f, 9.8f, 0f), Selection.upInDisplay(0f, -9.8f, 0f, 180).toList())
    }

    @Test
    fun segmentByteBudget() {
        // 35 Mbps + 128 kbps for 5 minutes = 1,317,300,000 bytes.
        assertEquals(1_317_300_000L, Selection.segmentByteBudget(35_000_000, 128_000, 300_000))
        // Clamped to stay well under 4 GB.
        assertEquals(3_800_000_000L, Selection.segmentByteBudget(100_000_000, 128_000, 3_600_000))
    }

    @Test
    fun thermalMapping() {
        assertEquals("nominal", Selection.thermalState(-1))
        assertEquals("nominal", Selection.thermalState(0))
        assertEquals("fair", Selection.thermalState(1))
        assertEquals("fair", Selection.thermalState(2))
        assertEquals("serious", Selection.thermalState(3))
        assertEquals("critical", Selection.thermalState(4))
        assertEquals("critical", Selection.thermalState(6))
    }

    @Test
    fun orientationHintForTypicalPhone() {
        // Sensor mounted at 90, display rotated 90 (landscape, top to the left): upright as captured.
        assertEquals(0, Selection.orientationHint(90, 90))
        // Display rotated 270 (landscape, top to the right): upside down as captured.
        assertEquals(180, Selection.orientationHint(90, 270))
        // Sensor at 270 (some devices) and display at 90.
        assertEquals(180, Selection.orientationHint(270, 90))
        assertEquals(90, Selection.orientationHint(90, 0))
    }

    @Test
    fun uprightSizeSwapsForQuarterTurns() {
        assertEquals(Dim(1920, 1080), Selection.uprightSize(Dim(1920, 1080), 0))
        assertEquals(Dim(1920, 1080), Selection.uprightSize(Dim(1920, 1080), 180))
        assertEquals(Dim(1080, 1920), Selection.uprightSize(Dim(1920, 1080), 90))
    }

    @Test
    fun previewTexCoordIdentityAtRotationZero() {
        for ((gx, gy) in listOf(0f to 0f, 1f to 0f, 0f to 1f, 1f to 1f)) {
            assertEquals(gx to gy, Selection.previewTexCoord(gx, gy, 0))
        }
    }

    @Test
    fun previewTexCoordRotation90() {
        // Display rotation 90: interface "up" is the natural right edge and
        // interface "right" is the natural bottom edge. So the output's
        // top-left (gx=0, gy=1) samples the natural top-right (x=1, y=0),
        // which in GL texture convention is st (1, 1).
        assertEquals(1f to 1f, Selection.previewTexCoord(0f, 1f, 90))
        // Output top-right samples natural bottom-right: st (1, 0).
        assertEquals(1f to 0f, Selection.previewTexCoord(1f, 1f, 90))
        // 270 is the opposite: output top-left samples natural bottom-left, st (0, 0).
        assertEquals(0f to 0f, Selection.previewTexCoord(0f, 1f, 270))
    }

    @Test
    fun lensChoicePrefersLogicalMinZoom() {
        val choice = Selection.chooseLenses(listOf(LensOption("0", 0.75, 0.5f), LensOption("1", 0.6, 1f)))!!
        assertEquals(LensPick("0", 1f), choice.wide)
        assertEquals(LensPick("0", 0.5f), choice.ultrawide)
    }

    @Test
    fun lensChoicePicksStandaloneUltrawide() {
        val choice = Selection.chooseLenses(
            listOf(LensOption("0", 0.75, 1f), LensOption("2", 1.25, 1f), LensOption("3", 0.3, 1f)),
        )!!
        assertEquals(LensPick("0", 1f), choice.wide)
        assertEquals(LensPick("2", 1f), choice.ultrawide)
    }

    @Test
    fun noUltrawideWhenOnlyOneLens() {
        val choice = Selection.chooseLenses(listOf(LensOption("0", 0.75, 1f)))!!
        assertNull(choice.ultrawide)
        assertNull(Selection.chooseLenses(emptyList()))
    }

    @Test
    fun fovFor43SensorRecording169() {
        // 6.4 x 4.8 mm sensor, 4 mm lens: full width used for 16:9 -> 2*atan(0.8) = 77.32 deg.
        val fov = Selection.horizontalFovDeg(
            6.4f, 4.8f, Dim(4000, 3000), Dim(4000, 3000), 4f, Dim(3840, 2160), 0, 1f,
        )
        assertNotNull(fov)
        assertTrue(abs(fov - 77.32) < 0.05, "fov=$fov")
        // At zoom 0.5 the half-width doubles: 2*atan(1.6) = 116.0 deg.
        val wide = Selection.horizontalFovDeg(
            6.4f, 4.8f, Dim(4000, 3000), Dim(4000, 3000), 4f, Dim(3840, 2160), 0, 0.5f,
        )!!
        assertTrue(abs(wide - 116.0) < 0.1, "fov=$wide")
    }

    private val all = { _: Dim, _: Int -> true }

    @Test
    fun exactModeWhenSupported() {
        val req = VideoMode(Dim(3840, 2160), 30, Codec.HEVC)
        val mode = Selection.chooseVideoMode(
            req, listOf(Dim(1920, 1080), Dim(3840, 2160), Dim(4000, 3000)), listOf(15, 30), all,
        ) { _, _, _ -> true }
        assertEquals(req, mode)
    }

    @Test
    fun fallsBackToH264WhenHevcMissing() {
        val req = VideoMode(Dim(3840, 2160), 30, Codec.HEVC)
        val mode = Selection.chooseVideoMode(req, listOf(Dim(3840, 2160)), listOf(30), all) { c, _, _ ->
            c == Codec.H264
        }
        assertEquals(VideoMode(Dim(3840, 2160), 30, Codec.H264), mode)
    }

    @Test
    fun prefersSizeOverCodec() {
        val req = VideoMode(Dim(3840, 2160), 30, Codec.HEVC)
        val mode = Selection.chooseVideoMode(
            req, listOf(Dim(1920, 1080), Dim(3840, 2160)), listOf(30), all,
        ) { c, s, _ -> c == Codec.H264 || s.width <= 1920 }
        assertEquals(VideoMode(Dim(3840, 2160), 30, Codec.H264), mode)
    }

    @Test
    fun fallsBackToSmallerSameAspectSize() {
        val req = VideoMode(Dim(3840, 2160), 30, Codec.HEVC)
        val mode = Selection.chooseVideoMode(
            req,
            listOf(Dim(4000, 3000), Dim(2560, 1440), Dim(1920, 1080), Dim(3840, 2160)),
            listOf(30),
            { s, _ -> s.width < 3840 },
        ) { _, _, _ -> true }
        assertEquals(Dim(2560, 1440), mode!!.size)
    }

    @Test
    fun fallsBackToNearestFps() {
        val req = VideoMode(Dim(1920, 1080), 30, Codec.HEVC)
        val mode = Selection.chooseVideoMode(req, listOf(Dim(1920, 1080)), listOf(24, 60), { _, f -> f != 30 }) { _, _, _ ->
            true
        }
        assertEquals(24, mode!!.fps)
    }

    @Test
    fun nothingSupportedGivesNull() {
        val req = VideoMode(Dim(1920, 1080), 30, Codec.HEVC)
        assertNull(Selection.chooseVideoMode(req, listOf(Dim(1920, 1080)), listOf(30), all) { _, _, _ -> false })
    }

    @Test
    fun fpsRangePrefersFixed() {
        assertEquals(30 to 30, Selection.chooseFpsRange(listOf(15 to 30, 30 to 30, 24 to 24), 30))
        assertEquals(24 to 30, Selection.chooseFpsRange(listOf(15 to 30, 24 to 30), 30))
        assertNull(Selection.chooseFpsRange(listOf(15 to 24), 30))
    }

    @Test
    fun previewSizeMatchesAspectUnder1080p() {
        val options = listOf(Dim(3840, 2160), Dim(1920, 1080), Dim(1440, 1080), Dim(1280, 720), Dim(640, 480))
        assertEquals(Dim(1920, 1080), Selection.choosePreviewSize(options, Dim(3840, 2160)))
        assertEquals(Dim(1440, 1080), Selection.choosePreviewSize(options, Dim(4000, 3000)))
    }
}
