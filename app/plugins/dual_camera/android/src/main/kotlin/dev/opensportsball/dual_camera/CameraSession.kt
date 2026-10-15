// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

package dev.opensportsball.dual_camera

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.MediaCodec
import android.media.MediaMetadataRetriever
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.StatFs
import android.os.SystemClock
import android.util.Log
import android.util.Range
import android.util.Size
import android.view.Surface
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.concurrent.Executor

internal data class OpenArgs(
    val width: Int,
    val height: Int,
    val fps: Int,
    val codec: Codec,
    val bitrateBps: Int,
    val ultrawide: Boolean,
    val segmentDurationMs: Long,
    val lockExposure: Boolean,
)

/**
 * Camera2 + MediaRecorder pipeline. One capture session is created at open
 * with two outputs: the preview renderer's SurfaceTexture and a persistent
 * MediaCodec input surface. Recordings attach a fresh MediaRecorder to that
 * persistent surface, so starting, stopping and rotating segment files never
 * reconfigures the session.
 *
 * Threading: every field below is confined to [handler]'s thread. Public
 * methods may be called from any thread; they post to it. Replies and
 * events are delivered on the main thread by [Reply] and [EventEmitter].
 */
internal class CameraSession(
    private val context: Context,
    private val events: EventEmitter,
    private val main: Handler,
) {
    private val thread = HandlerThread("DualCamera").apply { start() }
    private val handler = Handler(thread.looper)
    private val executor = Executor { handler.post(it) }
    private val cameraManager = context.getSystemService(CameraManager::class.java)

    /** Read from the main thread by `status`. */
    @Volatile var isRecording = false
        private set

    /** Directory of the current or last recording; used by `status` for free space. */
    @Volatile var storageDirectory: File? = null
        private set

    private var opened: Opened? = null
    private var recording: Recording? = null
    private var lastResult: TotalCaptureResult? = null
    private val waiters = mutableListOf<ResultWaiter>()

    // --- state types ------------------------------------------------------

    private enum class State { OPENING, READY, CLOSED }

    private enum class FocusLock { NONE, INFINITY, HOLD }

    private class Opened(
        val cameraId: String,
        val chars: CameraCharacteristics,
        val lens: String,
        val zoomRatio: Float,
        var mode: VideoMode,
        val bitrate: Int,
        val fpsRange: Range<Int>,
        val previewSize: Dim,
        val previewOut: Dim,
        val orientationHint: Int,
        val segmentDurationMs: Long,
        val lockExposure: Boolean,
        val fovDeg: Double?,
        val producer: TextureRegistry.SurfaceProducer,
        val openReply: Reply,
    ) {
        @Volatile var state = State.OPENING
        var renderer: PreviewRenderer? = null
        var recorderSurface: Surface? = null
        var device: CameraDevice? = null
        var session: CameraCaptureSession? = null
        var cameraLost = false
        var resourcesReleased = false

        // Locks applied to every request.
        var awbLock = false
        var aeLock = false
        var focusLock = FocusLock.NONE

        val afModes: IntArray = chars.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES) ?: IntArray(0)
        val minFocusDistance: Float = chars.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE) ?: 0f
        val oisOffAvailable: Boolean =
            chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION)
                ?.contains(CameraMetadata.LENS_OPTICAL_STABILIZATION_MODE_OFF) == true
        val awbLockAvailable: Boolean = chars.get(CameraCharacteristics.CONTROL_AWB_LOCK_AVAILABLE) == true
        val aeLockAvailable: Boolean = chars.get(CameraCharacteristics.CONTROL_AE_LOCK_AVAILABLE) == true
        val timestampRealtime: Boolean = chars.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE) ==
            CameraMetadata.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME
        val zoomRatioSupported: Boolean = Build.VERSION.SDK_INT >= 30 &&
            chars.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE) != null
    }

    private class Recording(
        val dir: File,
        val prefix: String,
        val recorder: MediaRecorder,
        var currentFile: File,
        val startWallMs: Long,
        /** CLOCK_MONOTONIC ns before which MediaRecorder drops frames. */
        val skipBeforeMonoNs: Long,
    ) {
        var index = 0
        var nextFile: File? = null
        var segmentStartMs = startWallMs
        var segmentWallStartMs = startWallMs
        var firstFrameSeen = false
        var pendingStart: Reply? = null
        var startTimeout: Runnable? = null
        var recordSequenceId = -1
        var stopping = false
        var finished = false
        var sequenceTimeout: Runnable? = null
        var storagePoll: Runnable? = null
        val afterStop = mutableListOf<() -> Unit>()
    }

    private class ResultWaiter(
        var framesToSkip: Int,
        val predicate: (TotalCaptureResult) -> Boolean,
        val onDone: (result: TotalCaptureResult?, cancelled: Boolean) -> Unit,
    ) {
        var timeout: Runnable? = null
    }

    // --- public API (any thread) -------------------------------------------

    fun availableLenses(reply: Reply) = post(reply) {
        val choice = try {
            CameraSelection.discover(cameraManager)
        } catch (e: CameraError) {
            null // no back camera: report an empty list rather than an error
        }
        reply.success(
            when {
                choice == null -> emptyList()
                choice.ultrawide != null -> listOf("ultrawide", "wide")
                else -> listOf("wide")
            },
        )
    }

    /**
     * [producer] must have been created on the main thread; on failure it is
     * released here.
     */
    fun open(
        args: OpenArgs,
        producer: TextureRegistry.SurfaceProducer,
        displayRotationDeg: Int,
        reply: Reply,
    ) = handler.post {
        try {
            if (recording != null) throw CameraError(Codes.ALREADY_RECORDING, "Stop recording before reopening")
            opened?.let { teardown(it) }
            if (!granted(Manifest.permission.CAMERA)) throw CameraError(Codes.PERMISSION_DENIED, "Camera permission not granted")
            startOpen(args, producer, displayRotationDeg, reply)
        } catch (e: CameraError) {
            main.post { producer.release() }
            reply.error(e)
        } catch (e: Exception) {
            Log.e(TAG, "open failed", e)
            main.post { producer.release() }
            reply.error(Codes.INTERNAL, e.toString())
        }
    }

    /** Stops (or resumes) drawing preview frames. Recording is unaffected. */
    fun setPreviewPaused(paused: Boolean, reply: Reply) = post(reply) {
        opened?.renderer?.paused = paused
        reply.success(null)
    }

    fun lockSettings(reply: Reply) = post(reply) {
        val o = readyOrThrow()
        // Re-meter from scratch: release any previous locks first.
        o.awbLock = false
        o.aeLock = false
        o.focusLock = FocusLock.NONE
        updateRepeating(o)
        waitForResult(timeoutMs = 3000, skipFrames = 3, predicate = ::isConverged) { result, cancelled ->
            if (cancelled || o.state != State.READY) {
                reply.error(Codes.NOT_OPEN, "Camera closed while metering")
                return@waitForResult
            }
            if (result == null) Log.w(TAG, "lockSettings: 3A did not converge in time; locking current values")
            applyLocks(o)
            updateRepeating(o)
            waitForResult(timeoutMs = 1500, skipFrames = 1, predicate = { isLocked(o, it) }) { locked, cancelled2 ->
                if (cancelled2 || o.state != State.READY) {
                    reply.error(Codes.NOT_OPEN, "Camera closed while locking")
                    return@waitForResult
                }
                reply.success(lockReport(o, locked ?: lastResult))
            }
        }
    }

    fun startRecording(directory: String, prefix: String, uprightRotationDeg: Int, reply: Reply) = post(reply) {
        val o = readyOrThrow()
        if (recording != null) throw CameraError(Codes.ALREADY_RECORDING, "Already recording")
        if (!granted(Manifest.permission.RECORD_AUDIO)) {
            throw CameraError(Codes.PERMISSION_DENIED, "Microphone permission not granted")
        }
        val dir = File(directory)
        if (!dir.isDirectory && !dir.mkdirs()) throw CameraError(Codes.IO_ERROR, "Cannot create $directory")
        if (!dir.canWrite()) throw CameraError(Codes.IO_ERROR, "$directory is not writable")
        storageDirectory = dir
        if (freeBytes(dir) < Selection.LOW_STORAGE_BYTES) {
            throw CameraError(Codes.IO_ERROR, "Less than 500 MB of free storage")
        }

        val file0 = freshFile(dir, prefix, 0)
        val recorder = newRecorder()
        try {
            configureRecorder(recorder, o, file0, withAudio = true, uprightRotationDeg = uprightRotationDeg)
            // Android only rotates output files on the size limit (there is no
            // public "duration approaching" event), so segments are cut by a
            // byte budget equal to bitrate x segment duration. See CHANNEL.md.
            recorder.setMaxFileSize(Selection.segmentByteBudget(o.bitrate, AUDIO_BITRATE, o.segmentDurationMs))
            recorder.prepare()
            recorder.start()
        } catch (e: Exception) {
            recorder.release()
            file0.delete()
            throw CameraError(Codes.IO_ERROR, "Could not start the recorder: ${e.message}", e)
        }

        // With a Surface video source MediaRecorder drops frames timestamped
        // before start() + 100 ms (StagefrightRecorder's start-time offset,
        // applied as MediaCodec "skip-frames-before"). Mirror that so the
        // reported start time is that of the first frame actually in the file.
        val rec = Recording(
            dir, prefix, recorder, file0,
            startWallMs = System.currentTimeMillis() + RECORDER_START_OFFSET_MS,
            skipBeforeMonoNs = System.nanoTime() + RECORDER_START_OFFSET_MS * 1_000_000,
        )
        rec.pendingStart = reply
        recorder.setOnInfoListener { _, what, _ -> onRecorderInfo(rec, what) }
        recorder.setOnErrorListener { _, what, extra -> onRecorderError(rec, what, extra) }
        recording = rec
        isRecording = true

        try {
            updateRepeating(o)
        } catch (e: Exception) {
            // Undo; the recorder has no frames, so stop() would throw.
            recording = null
            isRecording = false
            try { recorder.reset() } catch (_: Exception) {}
            recorder.release()
            file0.delete()
            throw CameraError(Codes.INTERNAL, "Could not start the record stream: ${e.message}", e)
        }

        // The reply waits for the first recorded frame (see onRecordFrameStarted),
        // with a fallback in case the timestamp never arrives.
        rec.startTimeout = Runnable { resolveStart(rec, rec.startWallMs) }.also { handler.postDelayed(it, 1500) }
        scheduleStoragePoll(rec)
    }

    fun stopRecording(reply: Reply) = post(reply) {
        if (recording == null) throw CameraError(Codes.NOT_RECORDING, "Not recording")
        stopRecordingInternal { reply.success(emptyMap<String, Any>()) }
    }

    fun close(reply: Reply) = post(reply) {
        closeAll { reply.success(null) }
    }

    /** For engine detach: close everything, no reply. */
    fun shutdown() {
        handler.post {
            closeAll {
                // Give onClosed / the release safety net time to run first.
                handler.postDelayed({ thread.quitSafely() }, 3500)
            }
        }
    }

    // --- open ---------------------------------------------------------------

    private fun startOpen(
        args: OpenArgs,
        producer: TextureRegistry.SurfaceProducer,
        displayRotationDeg: Int,
        reply: Reply,
    ) {
        val lenses = CameraSelection.discover(cameraManager)
        val pick = if (args.ultrawide && lenses.ultrawide != null) lenses.ultrawide else lenses.wide
        val lens = if (pick === lenses.ultrawide) "ultrawide" else "wide"
        val chars = cameraManager.getCameraCharacteristics(pick.cameraId)
        val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?: throw CameraError(Codes.UNSUPPORTED_CONFIG, "Camera ${pick.cameraId} has no stream configurations")

        val recSizes = map.getOutputSizes(MediaRecorder::class.java)?.map { Dim(it.width, it.height) }.orEmpty()
        val fpsRanges = chars.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            ?.map { it.lower to it.upper }.orEmpty()
        val requested = VideoMode(Dim(args.width, args.height), args.fps, args.codec)
        val mode = Selection.chooseVideoMode(
            requested,
            recSizes,
            fpsRanges.map { it.second },
            cameraSupports = { size, fps ->
                if (fpsRanges.none { it.second == fps }) {
                    false
                } else {
                    val minNs = map.getOutputMinFrameDuration(MediaRecorder::class.java, Size(size.width, size.height))
                    minNs <= 0L || minNs <= 1_000_000_000L / fps + 1000
                }
            },
            encoderSupports = { codec, size, fps -> Encoders.supports(codec, size, fps) },
        ) ?: throw CameraError(Codes.UNSUPPORTED_CONFIG, "No supported recording size, frame rate and codec")
        val fpsRange = Selection.chooseFpsRange(fpsRanges, mode.fps)
            ?: throw CameraError(Codes.UNSUPPORTED_CONFIG, "No AE frame-rate range for ${mode.fps} fps")
        val previewOptions = map.getOutputSizes(SurfaceTexture::class.java)?.map { Dim(it.width, it.height) }.orEmpty()
        val previewSize = Selection.choosePreviewSize(previewOptions, mode.size)
            ?: throw CameraError(Codes.UNSUPPORTED_CONFIG, "No preview size")
        val sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
        val hint = Selection.orientationHint(sensorOrientation, displayRotationDeg)
        val previewOut = Selection.uprightSize(previewSize, hint)
        val fov = CameraSelection.horizontalFovDeg(chars, mode.size, hint, pick.zoomRatio)
        val bitrate = Encoders.clampBitrate(mode.codec, mode.size, mode.fps, args.bitrateBps)

        Log.i(
            TAG,
            "open camera=${pick.cameraId} lens=$lens zoom=${pick.zoomRatio} mode=$mode bitrate=$bitrate " +
                "fpsRange=$fpsRange preview=$previewSize->$previewOut sensorOrientation=$sensorOrientation " +
                "display=$displayRotationDeg hint=$hint fov=$fov",
        )

        val o = Opened(
            cameraId = pick.cameraId, chars = chars, lens = lens, zoomRatio = pick.zoomRatio,
            mode = mode, bitrate = bitrate, fpsRange = Range(fpsRange.first, fpsRange.second),
            previewSize = previewSize, previewOut = previewOut, orientationHint = hint,
            segmentDurationMs = args.segmentDurationMs, lockExposure = args.lockExposure, fovDeg = fov,
            producer = producer, openReply = reply,
        )
        opened = o
        try {
            o.recorderSurface = createRecorderSurface(o)
            val renderer = PreviewRenderer(previewSize, previewOut, displayRotationDeg)
            o.renderer = renderer
            main.post {
                if (o.state == State.CLOSED) return@post
                producer.setSize(previewOut.width, previewOut.height)
                producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                    override fun onSurfaceAvailable() {
                        renderer.setOutputSurface(producer.surface)
                    }

                    override fun onSurfaceCleanup() {
                        // Must stop drawing before returning: the surface is released next.
                        renderer.setOutputSurfaceSync(null)
                    }
                })
                renderer.setOutputSurface(producer.surface)
            }
            openDevice(o)
        } catch (e: Exception) {
            val err = e as? CameraError ?: CameraError(Codes.INTERNAL, e.toString(), e)
            Log.w(TAG, "open failed: ${err.message}")
            reply.error(err)
            teardown(o) // also releases the producer
        }
    }

    /**
     * Creates the persistent recorder surface and sizes it by preparing (but
     * not starting) a throwaway video-only recorder, which is the documented
     * way to make it usable as a camera output before any recording.
     * Falls back from HEVC to H.264 if the encoder refuses the mode.
     */
    private fun createRecorderSurface(o: Opened): Surface {
        val surface = MediaCodec.createPersistentInputSurface()
        // configureRecorder() reads it from here.
        o.recorderSurface = surface
        val probe = File(context.cacheDir, "dual_camera_probe.mp4")
        val codecs = if (o.mode.codec == Codec.HEVC) listOf(Codec.HEVC, Codec.H264) else listOf(Codec.H264)
        var lastError: Exception? = null
        for (codec in codecs) {
            o.mode = o.mode.copy(codec = codec)
            val r = newRecorder()
            try {
                configureRecorder(r, o, probe, withAudio = false)
                r.prepare()
                probe.delete()
                return surface
            } catch (e: Exception) {
                Log.w(TAG, "recorder probe failed for $codec: ${e.message}")
                lastError = e
            } finally {
                r.release()
                probe.delete()
            }
        }
        o.recorderSurface = null
        surface.release()
        throw CameraError(Codes.UNSUPPORTED_CONFIG, "The video encoder rejected ${o.mode.size}@${o.mode.fps}: ${lastError?.message}", lastError)
    }

    @SuppressLint("MissingPermission") // checked in open()
    private fun openDevice(o: Opened) {
        val callback = object : CameraDevice.StateCallback() {
            override fun onOpened(device: CameraDevice) {
                if (o.state == State.CLOSED || opened !== o) {
                    device.close()
                    return
                }
                o.device = device
                try {
                    createSession(o, device)
                } catch (e: Exception) {
                    failOpen(o, Codes.CAMERA_UNAVAILABLE, "Could not create capture session: ${e.message}")
                }
            }

            override fun onDisconnected(device: CameraDevice) {
                o.device = device
                cameraFailed(o, "camera_disconnected", "The camera was disconnected")
            }

            override fun onError(device: CameraDevice, error: Int) {
                o.device = device
                val reason = when (error) {
                    ERROR_CAMERA_IN_USE -> "camera_in_use"
                    ERROR_MAX_CAMERAS_IN_USE -> "max_cameras_in_use"
                    ERROR_CAMERA_DISABLED -> "camera_disabled"
                    ERROR_CAMERA_DEVICE -> "camera_device_error"
                    ERROR_CAMERA_SERVICE -> "camera_service_error"
                    else -> "camera_error_$error"
                }
                cameraFailed(o, reason, "Camera error $error ($reason)")
            }

            override fun onClosed(device: CameraDevice) {
                releaseOutputs(o)
            }
        }
        try {
            cameraManager.openCamera(o.cameraId, callback, handler)
        } catch (e: SecurityException) {
            throw CameraError(Codes.PERMISSION_DENIED, "Camera permission not granted", e)
        } catch (e: Exception) {
            throw CameraError(Codes.CAMERA_UNAVAILABLE, "Could not open camera ${o.cameraId}: ${e.message}", e)
        }
    }

    private fun createSession(o: Opened, device: CameraDevice) {
        val renderer = o.renderer ?: throw IllegalStateException("no renderer")
        val recorderSurface = o.recorderSurface ?: throw IllegalStateException("no recorder surface")
        val callback = object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(session: CameraCaptureSession) {
                if (o.state == State.CLOSED || opened !== o) {
                    session.close()
                    return
                }
                o.session = session
                try {
                    o.state = State.READY
                    updateRepeating(o)
                } catch (e: Exception) {
                    failOpen(o, Codes.CAMERA_UNAVAILABLE, "Could not start preview: ${e.message}")
                    return
                }
                o.openReply.success(
                    mapOf(
                        "textureId" to o.producer.id(),
                        "previewWidth" to o.previewOut.width,
                        "previewHeight" to o.previewOut.height,
                        "width" to o.mode.size.width,
                        "height" to o.mode.size.height,
                        "fps" to o.mode.fps,
                        "codec" to o.mode.codec.wire,
                        "lens" to o.lens,
                        "horizontalFovDeg" to o.fovDeg,
                    ),
                )
            }

            override fun onConfigureFailed(session: CameraCaptureSession) {
                failOpen(o, Codes.UNSUPPORTED_CONFIG, "The camera rejected the preview + record stream combination")
            }
        }
        val outputs = listOf(OutputConfiguration(renderer.cameraSurface), OutputConfiguration(recorderSurface))
        if (Build.VERSION.SDK_INT >= 28) {
            device.createCaptureSession(
                SessionConfiguration(SessionConfiguration.SESSION_REGULAR, outputs, executor, callback),
            )
        } else {
            @Suppress("DEPRECATION")
            device.createCaptureSessionByOutputConfigurations(outputs, callback, handler)
        }
    }

    private fun failOpen(o: Opened, code: String, message: String) {
        Log.w(TAG, "open failed: $message")
        o.openReply.error(code, message)
        teardown(o)
    }

    private fun cameraFailed(o: Opened, reason: String, message: String) {
        if (o.state == State.CLOSED || opened !== o) {
            o.device?.close()
            return
        }
        if (o.state == State.OPENING) {
            failOpen(o, if (reason == "camera_disabled") Codes.PERMISSION_DENIED else Codes.CAMERA_UNAVAILABLE, message)
            return
        }
        Log.w(TAG, "camera lost: $message")
        o.cameraLost = true
        stopRecordingInternal {
            teardown(o)
            events.interrupted(reason)
        }
    }

    // --- requests -------------------------------------------------------------

    private fun buildRequest(o: Opened, record: Boolean): CaptureRequest {
        val device = o.device ?: throw IllegalStateException("no device")
        val b = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
        b.addTarget(o.renderer!!.cameraSurface)
        if (record) b.addTarget(o.recorderSurface!!)
        b.set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
        b.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, o.fpsRange)
        b.set(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE, CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_OFF)
        if (o.oisOffAvailable) {
            b.set(CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE, CameraMetadata.LENS_OPTICAL_STABILIZATION_MODE_OFF)
        }
        if (o.zoomRatioSupported && Build.VERSION.SDK_INT >= 30) {
            b.set(CaptureRequest.CONTROL_ZOOM_RATIO, o.zoomRatio)
        }
        b.set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_ON)
        b.set(CaptureRequest.CONTROL_AE_LOCK, o.aeLock)
        b.set(CaptureRequest.CONTROL_AWB_MODE, CameraMetadata.CONTROL_AWB_MODE_AUTO)
        b.set(CaptureRequest.CONTROL_AWB_LOCK, o.awbLock)
        when (o.focusLock) {
            FocusLock.NONE -> when {
                o.afModes.contains(CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_VIDEO) ->
                    b.set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                o.afModes.contains(CameraMetadata.CONTROL_AF_MODE_AUTO) ->
                    b.set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_AUTO)
                else -> Unit
            }
            FocusLock.INFINITY -> {
                b.set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_OFF)
                b.set(CaptureRequest.LENS_FOCUS_DISTANCE, 0f) // 0 = infinity
            }
            // AUTO without a trigger leaves the lens where continuous AF put it.
            FocusLock.HOLD -> b.set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_AUTO)
        }
        b.setTag(if (record) RECORD_TAG else PREVIEW_TAG)
        return b.build()
    }

    /** (Re)issues the repeating request; targets the recorder only while recording. */
    private fun updateRepeating(o: Opened) {
        val session = o.session ?: throw IllegalStateException("no session")
        val rec = recording
        val record = rec != null && !rec.stopping
        val seq = session.setRepeatingRequest(buildRequest(o, record), captureCallback, handler)
        if (rec != null && record) rec.recordSequenceId = seq
    }

    private val captureCallback = object : CameraCaptureSession.CaptureCallback() {
        override fun onCaptureStarted(
            session: CameraCaptureSession,
            request: CaptureRequest,
            timestamp: Long,
            frameNumber: Long,
        ) {
            if (request.tag == RECORD_TAG) onRecordFrameStarted(timestamp)
        }

        override fun onCaptureCompleted(
            session: CameraCaptureSession,
            request: CaptureRequest,
            result: TotalCaptureResult,
        ) {
            lastResult = result
            if (waiters.isEmpty()) return
            for (w in waiters.toList()) {
                if (w.framesToSkip > 0) {
                    w.framesToSkip--
                } else if (w.predicate(result)) {
                    waiters.remove(w)
                    w.timeout?.let { handler.removeCallbacks(it) }
                    w.onDone(result, false)
                }
            }
        }

        override fun onCaptureSequenceCompleted(session: CameraCaptureSession, sequenceId: Int, frameNumber: Long) {
            onSequenceDone(sequenceId)
        }

        override fun onCaptureSequenceAborted(session: CameraCaptureSession, sequenceId: Int) {
            onSequenceDone(sequenceId)
        }
    }

    private fun waitForResult(
        timeoutMs: Long,
        skipFrames: Int,
        predicate: (TotalCaptureResult) -> Boolean,
        onDone: (TotalCaptureResult?, Boolean) -> Unit,
    ) {
        val w = ResultWaiter(skipFrames, predicate, onDone)
        w.timeout = Runnable {
            if (waiters.remove(w)) w.onDone(null, false)
        }.also { handler.postDelayed(it, timeoutMs) }
        waiters += w
    }

    // --- 3A locking -----------------------------------------------------------

    private fun isConverged(r: TotalCaptureResult): Boolean {
        val ae = r.get(CaptureResult.CONTROL_AE_STATE)
        val awb = r.get(CaptureResult.CONTROL_AWB_STATE)
        val afMode = r.get(CaptureResult.CONTROL_AF_MODE)
        val af = r.get(CaptureResult.CONTROL_AF_STATE)
        val aeOk = ae == null || ae == CameraMetadata.CONTROL_AE_STATE_CONVERGED ||
            ae == CameraMetadata.CONTROL_AE_STATE_FLASH_REQUIRED || ae == CameraMetadata.CONTROL_AE_STATE_LOCKED
        val awbOk = awb == null || awb == CameraMetadata.CONTROL_AWB_STATE_CONVERGED ||
            awb == CameraMetadata.CONTROL_AWB_STATE_LOCKED
        val afOk = when (afMode) {
            CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_VIDEO, CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_PICTURE ->
                af == null || af == CameraMetadata.CONTROL_AF_STATE_PASSIVE_FOCUSED ||
                    af == CameraMetadata.CONTROL_AF_STATE_PASSIVE_UNFOCUSED ||
                    af == CameraMetadata.CONTROL_AF_STATE_FOCUSED_LOCKED ||
                    af == CameraMetadata.CONTROL_AF_STATE_NOT_FOCUSED_LOCKED
            else -> true
        }
        return aeOk && awbOk && afOk
    }

    private fun applyLocks(o: Opened) {
        o.awbLock = o.awbLockAvailable
        o.aeLock = o.lockExposure && o.aeLockAvailable
        val canFocus = o.minFocusDistance > 0f
        o.focusLock = when {
            !canFocus -> FocusLock.NONE // fixed focus: nothing to lock
            o.afModes.contains(CameraMetadata.CONTROL_AF_MODE_OFF) -> FocusLock.INFINITY
            o.afModes.contains(CameraMetadata.CONTROL_AF_MODE_AUTO) -> FocusLock.HOLD
            else -> FocusLock.NONE
        }
    }

    private fun isLocked(o: Opened, r: TotalCaptureResult): Boolean {
        val awb = r.get(CaptureResult.CONTROL_AWB_STATE)
        val ae = r.get(CaptureResult.CONTROL_AE_STATE)
        val awbOk = !o.awbLock || awb == null || awb == CameraMetadata.CONTROL_AWB_STATE_LOCKED
        val aeOk = !o.aeLock || ae == null || ae == CameraMetadata.CONTROL_AE_STATE_LOCKED
        val afOk = when (o.focusLock) {
            FocusLock.INFINITY -> r.get(CaptureResult.CONTROL_AF_MODE) == CameraMetadata.CONTROL_AF_MODE_OFF
            FocusLock.HOLD -> r.get(CaptureResult.CONTROL_AF_MODE) == CameraMetadata.CONTROL_AF_MODE_AUTO
            FocusLock.NONE -> true
        }
        return awbOk && aeOk && afOk
    }

    private fun lockReport(o: Opened, r: TotalCaptureResult?): Map<String, Boolean> {
        val awb = r?.get(CaptureResult.CONTROL_AWB_STATE)
        val ae = r?.get(CaptureResult.CONTROL_AE_STATE)
        val fixedFocus = o.minFocusDistance <= 0f
        return mapOf(
            "exposureLocked" to (o.aeLock && (ae == null || ae == CameraMetadata.CONTROL_AE_STATE_LOCKED)),
            "whiteBalanceLocked" to (o.awbLock && (awb == null || awb == CameraMetadata.CONTROL_AWB_STATE_LOCKED)),
            "focusLocked" to (fixedFocus || o.focusLock != FocusLock.NONE),
        )
    }

    // --- recording --------------------------------------------------------------

    @Suppress("DEPRECATION")
    private fun newRecorder(): MediaRecorder =
        if (Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else MediaRecorder()

    private fun configureRecorder(
        r: MediaRecorder, o: Opened, file: File, withAudio: Boolean, uprightRotationDeg: Int = 0,
    ) {
        if (withAudio) r.setAudioSource(MediaRecorder.AudioSource.CAMCORDER)
        r.setVideoSource(MediaRecorder.VideoSource.SURFACE)
        r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        r.setOutputFile(file)
        r.setVideoEncoder(
            when (o.mode.codec) {
                Codec.HEVC -> MediaRecorder.VideoEncoder.HEVC
                Codec.H264 -> MediaRecorder.VideoEncoder.H264
            },
        )
        r.setVideoEncodingBitRate(o.bitrate)
        r.setVideoFrameRate(o.mode.fps)
        r.setVideoSize(o.mode.size.width, o.mode.size.height)
        if (withAudio) {
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioSamplingRate(48_000)
            r.setAudioEncodingBitRate(AUDIO_BITRATE)
            r.setAudioChannels(1)
        }
        r.setOrientationHint(Selection.recordingHint(o.orientationHint, uprightRotationDeg))
        r.setInputSurface(o.recorderSurface ?: throw IllegalStateException("no recorder surface"))
    }

    private fun freshFile(dir: File, prefix: String, index: Int): File {
        val f = File(dir, Selection.segmentFileName(prefix, index))
        // MediaRecorder opens without truncating; never leave old bytes behind.
        if (f.exists() && !f.delete()) throw CameraError(Codes.IO_ERROR, "Cannot overwrite ${f.path}")
        return f
    }

    private fun onRecordFrameStarted(timestampNs: Long) {
        val rec = recording ?: return
        if (rec.firstFrameSeen) return
        val o = opened ?: return
        // Sensor timestamps are BOOTTIME (REALTIME source) or, in practice,
        // MONOTONIC (UNKNOWN source); buffers reaching the encoder are MONOTONIC.
        val monoNow = System.nanoTime()
        val tsMono = if (o.timestampRealtime) {
            timestampNs - (SystemClock.elapsedRealtimeNanos() - monoNow)
        } else {
            timestampNs
        }
        if (tsMono < rec.skipBeforeMonoNs) return // dropped by the recorder
        val ageNs = monoNow - tsMono
        val now = System.currentTimeMillis()
        val wall = if (ageNs in 0..5_000_000_000L) now - ageNs / 1_000_000 else now
        resolveStart(rec, wall)
    }

    private fun resolveStart(rec: Recording, wallMs: Long) {
        if (rec.firstFrameSeen) return
        rec.firstFrameSeen = true
        rec.startTimeout?.let { handler.removeCallbacks(it) }
        rec.segmentStartMs = wallMs
        rec.pendingStart?.success(mapOf("startedAtDeviceMs" to wallMs))
        rec.pendingStart = null
    }

    private fun onRecorderInfo(rec: Recording, what: Int) {
        if (recording !== rec || rec.finished) return
        when (what) {
            MediaRecorder.MEDIA_RECORDER_INFO_MAX_FILESIZE_APPROACHING -> {
                // Sent at 90% of the byte budget; the switch happens at 100%.
                if (rec.nextFile != null || rec.stopping) return
                try {
                    val next = freshFile(rec.dir, rec.prefix, rec.index + 1)
                    rec.recorder.setNextOutputFile(next)
                    rec.nextFile = next
                } catch (e: Exception) {
                    Log.e(TAG, "setNextOutputFile failed", e)
                    events.error(Codes.IO_ERROR, "Could not open the next segment file: ${e.message}", false)
                }
            }
            MediaRecorder.MEDIA_RECORDER_INFO_NEXT_OUTPUT_FILE_STARTED -> {
                val next = rec.nextFile ?: return
                val now = System.currentTimeMillis()
                val duration = emitSegment(rec.index, rec.currentFile, rec.segmentStartMs, now - rec.segmentWallStartMs)
                rec.index++
                rec.currentFile = next
                rec.nextFile = null
                rec.segmentStartMs += duration
                rec.segmentWallStartMs = now
            }
            MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED,
            MediaRecorder.MEDIA_RECORDER_INFO_MAX_FILESIZE_REACHED -> {
                // The recorder stopped itself: segment rotation did not happen.
                stopRecordingInternal {
                    events.error(Codes.IO_ERROR, "Segment rotation failed; recording stopped", true)
                }
            }
        }
    }

    private fun onRecorderError(rec: Recording, what: Int, extra: Int) {
        if (recording !== rec || rec.finished) return
        Log.e(TAG, "MediaRecorder error what=$what extra=$extra")
        stopRecordingInternal {
            events.error(Codes.INTERNAL, "Recorder error ($what/$extra); recording stopped", true)
        }
    }

    /**
     * Stops the current recording (if any), finalizes and reports the last
     * segment, then runs [then]. Safe to call repeatedly; later callers are
     * queued behind the stop in progress.
     */
    private fun stopRecordingInternal(then: () -> Unit) {
        val rec = recording
        if (rec == null) {
            then()
            return
        }
        rec.afterStop += then
        if (rec.stopping) return
        rec.stopping = true
        rec.storagePoll?.let { handler.removeCallbacks(it) }
        val o = opened
        val session = o?.session
        if (o != null && session != null && !o.cameraLost && o.state == State.READY) {
            try {
                // Point the repeating request back at the preview only, then
                // wait for the last record-targeted frame before stopping.
                updateRepeating(o)
                rec.sequenceTimeout = Runnable { finishStop(rec) }.also { handler.postDelayed(it, 500) }
                return
            } catch (e: Exception) {
                Log.w(TAG, "could not detach the record stream: ${e.message}")
            }
        }
        finishStop(rec)
    }

    private fun onSequenceDone(sequenceId: Int) {
        val rec = recording ?: return
        if (rec.stopping && sequenceId == rec.recordSequenceId) finishStop(rec)
    }

    private fun finishStop(rec: Recording) {
        if (rec.finished) return
        rec.finished = true
        rec.sequenceTimeout?.let { handler.removeCallbacks(it) }
        // Never leave startRecording hanging.
        resolveStart(rec, rec.startWallMs)

        var stopOk = true
        try {
            rec.recorder.stop()
        } catch (e: RuntimeException) {
            Log.w(TAG, "MediaRecorder.stop failed: ${e.message}")
            stopOk = false
        }
        try { rec.recorder.reset() } catch (_: Exception) {}
        rec.recorder.release()
        recording = null
        isRecording = false

        val now = System.currentTimeMillis()
        if (stopOk || rec.currentFile.length() > 0) {
            emitSegment(rec.index, rec.currentFile, rec.segmentStartMs, now - rec.segmentWallStartMs)
        }
        rec.nextFile?.let { if (it.length() == 0L) it.delete() }

        val callbacks = rec.afterStop.toList()
        rec.afterStop.clear()
        callbacks.forEach { it() }
    }

    /**
     * Reports a closed segment file. Returns the duration used for chaining
     * start times (measured if possible, else [wallDurationMs]).
     */
    private fun emitSegment(index: Int, file: File, startedAtMs: Long, wallDurationMs: Long): Long {
        val measured = measureDurationMs(file)
        if (measured == null) {
            Log.w(TAG, "segment $index (${file.path}) is unreadable")
            events.error(Codes.IO_ERROR, "Segment ${file.name} could not be finalized", false)
            return wallDurationMs.coerceAtLeast(0)
        }
        events.segment(index, file.absolutePath, file.length(), startedAtMs, measured)
        return measured
    }

    private fun measureDurationMs(file: File): Long? {
        if (!file.isFile || file.length() == 0L) return null
        val mmr = MediaMetadataRetriever()
        return try {
            mmr.setDataSource(file.absolutePath)
            mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
        } catch (e: Exception) {
            Log.w(TAG, "MediaMetadataRetriever: ${e.message}")
            null
        } finally {
            try { mmr.release() } catch (_: Exception) {}
        }
    }

    private fun scheduleStoragePoll(rec: Recording) {
        val poll = object : Runnable {
            override fun run() {
                if (recording !== rec || rec.stopping) return
                if (freeBytes(rec.dir) < Selection.LOW_STORAGE_BYTES) {
                    Log.w(TAG, "low storage, stopping")
                    stopRecordingInternal {
                        events.error(Codes.IO_ERROR, "Storage is almost full (under 500 MB); recording stopped", true)
                    }
                } else {
                    handler.postDelayed(this, STORAGE_POLL_MS)
                }
            }
        }
        rec.storagePoll = poll
        handler.postDelayed(poll, STORAGE_POLL_MS)
    }

    // --- teardown ---------------------------------------------------------------

    private fun closeAll(then: () -> Unit) {
        stopRecordingInternal {
            opened?.let { teardown(it) }
            then()
        }
    }

    /** Releases everything belonging to [o]. Idempotent. */
    private fun teardown(o: Opened) {
        if (o.state == State.CLOSED) return
        o.state = State.CLOSED
        if (opened === o) opened = null
        o.openReply.error(Codes.CAMERA_UNAVAILABLE, "Camera closed while opening")
        for (w in waiters.toList()) {
            w.timeout?.let { handler.removeCallbacks(it) }
            w.onDone(null, true)
        }
        waiters.clear()
        lastResult = null
        try { o.session?.close() } catch (e: Exception) { Log.w(TAG, "session close: ${e.message}") }
        o.session = null
        // Detach Flutter's surface first; the producer is released on the main thread.
        o.renderer?.setOutputSurfaceSync(null)
        main.post {
            o.producer.setCallback(null)
            o.producer.release()
        }
        val device = o.device
        if (device != null) {
            // Camera outputs are released in onClosed, once the camera has
            // stopped writing into them.
            try { device.close() } catch (e: Exception) { Log.w(TAG, "device close: ${e.message}") }
            handler.postDelayed({ releaseOutputs(o) }, 3000) // safety net
        } else {
            releaseOutputs(o)
        }
    }

    private fun releaseOutputs(o: Opened) {
        if (o.resourcesReleased) return
        o.resourcesReleased = true
        o.renderer?.release()
        o.recorderSurface?.release()
    }

    // --- helpers ------------------------------------------------------------------

    private fun readyOrThrow(): Opened {
        val o = opened
        if (o == null || o.state != State.READY) throw CameraError(Codes.NOT_OPEN, "Camera is not open")
        return o
    }

    private fun granted(permission: String) =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    fun freeBytes(dir: File): Long = try {
        StatFs(dir.path).availableBytes
    } catch (e: Exception) {
        Log.w(TAG, "StatFs(${dir.path}): ${e.message}")
        Long.MAX_VALUE
    }

    /** Runs [block] on the camera thread, mapping exceptions to replies. */
    private fun post(reply: Reply, block: () -> Unit) {
        handler.post {
            try {
                block()
            } catch (e: CameraError) {
                reply.error(e)
            } catch (e: Exception) {
                Log.e(TAG, "unexpected error", e)
                reply.error(Codes.INTERNAL, e.toString())
            }
        }
    }

    private companion object {
        const val RECORD_TAG = "dual_camera.record"
        const val PREVIEW_TAG = "dual_camera.preview"
        const val STORAGE_POLL_MS = 5000L
        const val AUDIO_BITRATE = 128_000
        const val RECORDER_START_OFFSET_MS = 100L
    }
}
