// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

package dev.opensportsball.dual_camera

import java.util.Locale
import kotlin.math.abs
import kotlin.math.atan
import kotlin.math.min

// Pure decision logic, kept free of android.* types so it can be unit tested
// on the JVM. Camera2 / MediaCodec queries are passed in as plain values or
// lambdas by the callers in CameraSession and CameraSelection.

internal data class Dim(val width: Int, val height: Int) {
    val area: Long get() = width.toLong() * height
    val aspect: Double get() = width.toDouble() / height
}

internal enum class Codec(val wire: String) {
    HEVC("hevc"),
    H264("h264");

    companion object {
        fun fromWire(s: String?): Codec = if (s == "h264") H264 else HEVC
    }
}

internal data class VideoMode(val size: Dim, val fps: Int, val codec: Codec)

/** One back camera as seen by lens selection. */
internal data class LensOption(
    val cameraId: String,
    /** tan(horizontal FOV / 2) at zoom ratio 1.0, along the sensor's long side. */
    val tanHalfFov: Double,
    /** Lowest CONTROL_ZOOM_RATIO (1.0 when the API or the camera doesn't offer one). */
    val minZoomRatio: Float,
)

internal data class LensPick(val cameraId: String, val zoomRatio: Float)

internal data class LensChoice(val wide: LensPick, val ultrawide: LensPick?)

internal object Selection {
    /** Below this much free space a recording is stopped (CHANNEL.md, requirement 9). */
    const val LOW_STORAGE_BYTES: Long = 500L * 1024 * 1024

    /** An ultrawide must be at least this much wider (in tan(fov/2)) than the wide lens. */
    private const val ULTRAWIDE_MIN_GAIN = 1.1

    private const val ASPECT_TOLERANCE = 0.01

    /** MP4 offsets stay 32-bit-safe and FAT-style limits are avoided below this. */
    private const val MAX_SEGMENT_BYTES: Long = 3_800_000_000L
    private const val MIN_SEGMENT_BYTES: Long = 8L * 1024 * 1024

    /**
     * Byte budget that makes MediaRecorder rotate files roughly every
     * [segmentDurationMs]: target bitrate x duration. Encoders usually run at
     * or under the target bitrate, so segments come out at or a little over
     * the requested duration.
     */
    fun segmentByteBudget(videoBitrate: Int, audioBitrate: Int, segmentDurationMs: Long): Long {
        val bits = (videoBitrate.toLong() + audioBitrate) * segmentDurationMs / 1000
        return (bits / 8).coerceIn(MIN_SEGMENT_BYTES, MAX_SEGMENT_BYTES)
    }

    fun segmentFileName(prefix: String, index: Int): String =
        String.format(Locale.ROOT, "%s_%03d.mp4", prefix, index)

    /**
     * Maps PowerManager.THERMAL_STATUS_* (0 none .. 6 shutdown) to the
     * contract's four states. -1 means "unknown / API < 29" and maps to nominal.
     */
    fun thermalState(status: Int): String = when {
        status <= 0 -> "nominal"          // NONE (or unknown)
        status <= 2 -> "fair"             // LIGHT, MODERATE
        status == 3 -> "serious"          // SEVERE
        else -> "critical"                // CRITICAL, EMERGENCY, SHUTDOWN
    }

    /** Surface.ROTATION_* (0..3) to degrees. */
    fun rotationToDegrees(rotation: Int): Int = (rotation and 3) * 90

    /**
     * An accelerometer / gravity sensor reading (device axes in the natural
     * orientation; it points away from the ground) turned into the
     * displayed picture's axes: x to its right, y to its top, z out of the
     * screen. The recording is upright in the interface, so this is also
     * "up" in the recorded frames.
     */
    fun upInDisplay(x: Float, y: Float, z: Float, displayRotationDeg: Int): FloatArray =
        when (((displayRotationDeg % 360) + 360) % 360) {
            90 -> floatArrayOf(-y, x, z)
            180 -> floatArrayOf(-x, -y, z)
            270 -> floatArrayOf(y, -x, z)
            else -> floatArrayOf(x, y, z)
        }

    /**
     * Clockwise rotation a player must apply to the encoded (sensor-oriented)
     * frames so they are upright for a back camera, given the display
     * rotation at the time the camera was opened.
     */
    fun orientationHint(sensorOrientation: Int, displayRotationDeg: Int): Int =
        ((sensorOrientation - displayRotationDeg) % 360 + 360) % 360

    /** Preview texture size after rotating a sensor-oriented buffer upright. */
    fun uprightSize(sensorSize: Dim, orientationHint: Int): Dim =
        if (orientationHint % 180 != 0) Dim(sensorSize.height, sensorSize.width) else sensorSize

    /**
     * Texture coordinate (before the SurfaceTexture transform) to sample for an
     * output pixel at GL position (gx, gy) in [0,1], origin bottom-left.
     *
     * The SurfaceTexture transform already rotates camera frames upright for
     * the device's natural orientation. This adds the display rotation so the
     * image is upright in the (landscape) interface orientation.
     */
    fun previewTexCoord(gx: Float, gy: Float, displayRotationDeg: Int): Pair<Float, Float> {
        // Interface coordinates, origin top-left.
        val u = gx
        val v = 1f - gy
        // Natural-orientation image coordinates, origin top-left.
        val (x, y) = when (((displayRotationDeg % 360) + 360) % 360) {
            90 -> Pair(1f - v, u)
            180 -> Pair(1f - u, 1f - v)
            270 -> Pair(v, 1f - u)
            else -> Pair(u, v)
        }
        // Back to GL texture convention (origin bottom-left).
        return Pair(x, 1f - y)
    }

    /**
     * Picks the wide lens (the first back camera, at zoom 1.0) and the
     * ultrawide (the widest effective field of view, using a logical
     * camera's minimum zoom ratio when below 1.0). Returns null when there is
     * no back camera at all.
     */
    fun chooseLenses(options: List<LensOption>): LensChoice? {
        if (options.isEmpty()) return null
        val wideOption = options.first()
        val wide = LensPick(wideOption.cameraId, 1f)
        fun effectiveTan(o: LensOption) = o.tanHalfFov / min(o.minZoomRatio, 1f)
        val widest = options.maxByOrNull { effectiveTan(it) }!!
        val ultra = if (effectiveTan(widest) > wideOption.tanHalfFov * ULTRAWIDE_MIN_GAIN) {
            LensPick(widest.cameraId, min(widest.minZoomRatio, 1f))
        } else {
            null
        }
        return LensChoice(wide, ultra)
    }

    /**
     * tan(horizontal FOV / 2) along the sensor's long side, from the active
     * array, at zoom 1.0. Used to compare lenses.
     */
    fun tanHalfFov(
        physicalWidthMm: Float,
        pixelArrayWidth: Int,
        activeWidth: Int,
        focalLengthMm: Float,
    ): Double? {
        if (physicalWidthMm <= 0f || pixelArrayWidth <= 0 || activeWidth <= 0 || focalLengthMm <= 0f) {
            return null
        }
        val activeMm = physicalWidthMm.toDouble() * activeWidth / pixelArrayWidth
        return activeMm / (2.0 * focalLengthMm)
    }

    /**
     * Horizontal field of view (degrees) of the recorded, upright video.
     *
     * The camera fits the output aspect ratio into the active array (centred,
     * maximal), then the zoom ratio scales the crop. When the orientation hint
     * is 90/270 the recorded horizontal axis is the sensor's vertical axis.
     */
    fun horizontalFovDeg(
        physicalWidthMm: Float,
        physicalHeightMm: Float,
        pixelArray: Dim,
        activeArray: Dim,
        focalLengthMm: Float,
        output: Dim,
        orientationHint: Int,
        zoomRatio: Float,
    ): Double? {
        if (physicalWidthMm <= 0f || physicalHeightMm <= 0f || focalLengthMm <= 0f || zoomRatio <= 0f) return null
        if (pixelArray.width <= 0 || pixelArray.height <= 0 || activeArray.width <= 0 || activeArray.height <= 0) return null
        if (output.width <= 0 || output.height <= 0) return null
        val usedW = min(activeArray.width.toDouble(), activeArray.height * output.aspect)
        val usedH = usedW / output.aspect
        val rotated = orientationHint % 180 != 0
        val mm = if (rotated) {
            usedH * physicalHeightMm / pixelArray.height
        } else {
            usedW * physicalWidthMm / pixelArray.width
        } / zoomRatio
        return Math.toDegrees(2.0 * atan(mm / (2.0 * focalLengthMm)))
    }

    private fun sameAspect(a: Dim, b: Dim) = abs(a.aspect - b.aspect) / b.aspect <= ASPECT_TOLERANCE

    /**
     * Ranks sizes by closeness to the requested one (lower is better):
     * exact; same aspect and not larger (largest first); not larger (closest
     * aspect, then largest); same aspect and larger (smallest first); anything
     * else (closest aspect, smallest).
     */
    fun sizeComparator(requested: Dim): Comparator<Dim> {
        fun category(s: Dim): Int = when {
            s == requested -> 0
            sameAspect(s, requested) && s.area <= requested.area -> 1
            s.area <= requested.area -> 2
            sameAspect(s, requested) -> 3
            else -> 4
        }
        return compareBy<Dim>(
            { category(it) },
            { abs(it.aspect - requested.aspect) },
            { if (category(it) <= 2) -it.area else it.area },
        )
    }

    /**
     * Chooses the closest supported recording mode. Priority: frame rate
     * (exact, else nearest, ties to the lower rate), then size, then codec.
     * Returns null if no combination is supported at all.
     */
    fun chooseVideoMode(
        requested: VideoMode,
        cameraSizes: List<Dim>,
        fpsOptions: List<Int>,
        cameraSupports: (Dim, Int) -> Boolean,
        encoderSupports: (Codec, Dim, Int) -> Boolean,
    ): VideoMode? {
        val sizeCmp = sizeComparator(requested.size)
        val codecs = listOf(requested.codec) + Codec.entries.filter { it != requested.codec }
        val fpsOrder = (fpsOptions + requested.fps).distinct().filter { it > 0 }
            .sortedWith(compareBy({ abs(it - requested.fps) }, { it }))
        val sizes = cameraSizes.distinct().sortedWith(sizeCmp)
        for (fps in fpsOrder) {
            for (size in sizes) {
                if (!cameraSupports(size, fps)) continue
                for (codec in codecs) {
                    if (encoderSupports(codec, size, fps)) return VideoMode(size, fps, codec)
                }
            }
        }
        return null
    }

    /**
     * AE target FPS range for [fps]: a fixed [fps, fps] range when offered
     * (constant frame rate), else the range ending at [fps] with the highest
     * lower bound. Ranges are (lower, upper).
     */
    fun chooseFpsRange(ranges: List<Pair<Int, Int>>, fps: Int): Pair<Int, Int>? =
        ranges.filter { it.second == fps }.maxByOrNull { it.first }

    /**
     * Preview stream size: same aspect ratio as the recording, at most
     * [max] (1080p), as large as possible. Falls back to the closest aspect.
     */
    fun choosePreviewSize(options: List<Dim>, recording: Dim, max: Dim = Dim(1920, 1080)): Dim? {
        val fits = options.filter { it.width <= max.width && it.height <= max.height }
        if (fits.isEmpty()) return options.minByOrNull { it.area }
        val same = fits.filter { sameAspect(it, recording) }
        if (same.isNotEmpty()) return same.maxByOrNull { it.area }
        return fits.sortedWith(compareBy({ abs(it.aspect - recording.aspect) }, { -it.area })).first()
    }
}
