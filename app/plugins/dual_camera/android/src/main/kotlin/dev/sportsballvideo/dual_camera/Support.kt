// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

package dev.sportsballvideo.dual_camera

import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

internal const val TAG = "DualCamera"

/** Error codes from CHANNEL.md. */
internal object Codes {
    const val PERMISSION_DENIED = "permission_denied"
    const val CAMERA_UNAVAILABLE = "camera_unavailable"
    const val UNSUPPORTED_CONFIG = "unsupported_config"
    const val NOT_OPEN = "not_open"
    const val ALREADY_RECORDING = "already_recording"
    const val NOT_RECORDING = "not_recording"
    const val IO_ERROR = "io_error"
    const val INTERNAL = "internal"
}

internal class CameraError(val code: String, message: String, cause: Throwable? = null) :
    Exception(message, cause)

/**
 * Wraps a MethodChannel.Result so it can be completed from any thread,
 * exactly once. The underlying result is always invoked on the main thread.
 */
internal class Reply(private val result: MethodChannel.Result, private val main: Handler) {
    private val done = AtomicBoolean(false)

    val isDone: Boolean get() = done.get()

    fun success(value: Any?) {
        if (done.compareAndSet(false, true)) main.post { result.success(value) }
    }

    fun error(code: String, message: String?) {
        if (done.compareAndSet(false, true)) main.post { result.error(code, message, null) }
    }

    fun error(e: CameraError) = error(e.code, e.message)
}

/**
 * Sends events to the Dart EventChannel on the main thread. Events sent while
 * nobody is listening are logged and dropped.
 */
internal class EventEmitter(private val main: Handler) : EventChannel.StreamHandler {
    private var sink: EventChannel.EventSink? = null // main thread only

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    fun send(event: Map<String, Any?>) {
        main.post {
            val s = sink
            if (s == null) {
                Log.w(TAG, "event dropped, no listener: $event")
            } else {
                s.success(event)
            }
        }
    }

    fun segment(index: Int, path: String, bytes: Long, startedAtDeviceMs: Long, durationMs: Long) =
        send(
            mapOf(
                "type" to "segment",
                "index" to index,
                "path" to path,
                "bytes" to bytes,
                "startedAtDeviceMs" to startedAtDeviceMs,
                "durationMs" to durationMs,
            ),
        )

    fun error(code: String, message: String, fatal: Boolean) =
        send(mapOf("type" to "error", "code" to code, "message" to message, "fatal" to fatal))

    fun interrupted(reason: String) = send(mapOf("type" to "interrupted", "reason" to reason))
}
