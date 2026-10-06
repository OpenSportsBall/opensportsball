// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

package dev.sportsballvideo.dual_camera

import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.util.Log

/** Back-camera discovery and lens choice on top of the pure [Selection] logic. */
internal object CameraSelection {
    fun discover(manager: CameraManager): LensChoice {
        val options = mutableListOf<LensOption>()
        for (id in manager.cameraIdList) {
            val chars = try {
                manager.getCameraCharacteristics(id)
            } catch (e: Exception) {
                Log.w(TAG, "skipping camera $id: ${e.message}")
                continue
            }
            if (chars.get(CameraCharacteristics.LENS_FACING) != CameraCharacteristics.LENS_FACING_BACK) continue
            val caps = chars.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES) ?: IntArray(0)
            if (!caps.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_BACKWARD_COMPATIBLE)) continue
            val tan = tanHalfFov(chars) ?: continue
            val minZoom = if (Build.VERSION.SDK_INT >= 30) {
                chars.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)?.lower ?: 1f
            } else {
                1f
            }
            Log.i(TAG, "back camera $id: tan(hfov/2)=$tan minZoom=$minZoom")
            options += LensOption(id, tan, minZoom)
        }
        return Selection.chooseLenses(options)
            ?: throw CameraError(Codes.CAMERA_UNAVAILABLE, "No usable back camera")
    }

    private fun tanHalfFov(chars: CameraCharacteristics): Double? {
        val phys = chars.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE) ?: return null
        val pixels = chars.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE) ?: return null
        val active = chars.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE) ?: return null
        val focal = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.firstOrNull() ?: return null
        return Selection.tanHalfFov(phys.width, pixels.width, active.width(), focal)
    }

    fun horizontalFovDeg(
        chars: CameraCharacteristics,
        output: Dim,
        orientationHint: Int,
        zoomRatio: Float,
    ): Double? {
        val phys = chars.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE) ?: return null
        val pixels = chars.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE) ?: return null
        val active = chars.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE) ?: return null
        val focal = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.firstOrNull() ?: return null
        return Selection.horizontalFovDeg(
            phys.width, phys.height,
            Dim(pixels.width, pixels.height),
            Dim(active.width(), active.height()),
            focal, output, orientationHint, zoomRatio,
        )
    }
}

/** Video encoder capability queries via MediaCodecList. */
internal object Encoders {
    private val encoders: List<MediaCodecInfo> by lazy {
        MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { it.isEncoder }
    }

    private fun mime(codec: Codec) = when (codec) {
        Codec.HEVC -> MediaFormat.MIMETYPE_VIDEO_HEVC
        Codec.H264 -> MediaFormat.MIMETYPE_VIDEO_AVC
    }

    private fun isSoftware(info: MediaCodecInfo): Boolean {
        if (Build.VERSION.SDK_INT >= 29) return info.isSoftwareOnly
        val n = info.name.lowercase()
        return n.startsWith("omx.google.") || n.startsWith("c2.android.")
    }

    /** Hardware encoders for [codec] (software ones cannot keep up with 4K). */
    private fun capabilities(codec: Codec): List<MediaCodecInfo.VideoCapabilities> {
        val type = mime(codec)
        return encoders
            .filter { info -> !isSoftware(info) && info.supportedTypes.any { it.equals(type, ignoreCase = true) } }
            .mapNotNull { info ->
                try {
                    info.getCapabilitiesForType(type).videoCapabilities
                } catch (e: Exception) {
                    null
                }
            }
    }

    fun supports(codec: Codec, size: Dim, fps: Int): Boolean =
        capabilities(codec).any { it.areSizeAndRateSupported(size.width, size.height, fps.toDouble()) }

    /** Clamps [bitrate] into the range of an encoder that supports the mode. */
    fun clampBitrate(codec: Codec, size: Dim, fps: Int, bitrate: Int): Int {
        val caps = capabilities(codec).firstOrNull {
            it.areSizeAndRateSupported(size.width, size.height, fps.toDouble())
        } ?: return bitrate
        return caps.bitrateRange.clamp(bitrate)
    }
}
