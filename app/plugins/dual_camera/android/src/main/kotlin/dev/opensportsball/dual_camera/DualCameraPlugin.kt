// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

package dev.opensportsball.dual_camera

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.view.Surface
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import io.flutter.view.TextureRegistry

/**
 * Flutter entry point for the dual_camera channel contract (CHANNEL.md).
 * Camera work lives in [CameraSession]; this class handles the channel,
 * permissions, device status and the activity window.
 */
class DualCameraPlugin :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private val main = Handler(Looper.getMainLooper())
    private lateinit var context: Context
    private lateinit var textures: TextureRegistry
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var events: EventEmitter
    private var session: CameraSession? = null

    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPermissions: Reply? = null
    private var pendingBluetooth: Reply? = null

    // --- FlutterPlugin ------------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        textures = binding.textureRegistry
        events = EventEmitter(main)
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(events)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        session?.shutdown()
        session = null
    }

    private fun session(): CameraSession =
        session ?: CameraSession(context, events, main).also { session = it }

    // --- ActivityAware --------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
    }

    private val activity: Activity? get() = activityBinding?.activity

    // --- MethodCallHandler ----------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: Result) {
        val reply = Reply(result, main)
        try {
            when (call.method) {
                "checkPermissions" -> reply.success(permissionState())
                "requestPermissions" -> requestPermissions(reply)
                "requestBluetoothPermission" -> requestBluetoothPermission(reply)
                "availableLenses" -> session().availableLenses(reply)
                "open" -> open(call, reply)
                "lockSettings" -> session().lockSettings(reply)
                "startRecording" -> {
                    val dir = call.argument<String>("directory")
                    val prefix = call.argument<String>("filePrefix")
                    if (dir.isNullOrEmpty() || prefix.isNullOrEmpty()) {
                        reply.error(Codes.INTERNAL, "startRecording needs directory and filePrefix")
                    } else {
                        session().startRecording(dir, prefix, reply)
                    }
                }
                "stopRecording" -> session().stopRecording(reply)
                "status" -> reply.success(status())
                "setKeepScreenOn" -> setKeepScreenOn(call.argument<Boolean>("on") == true, reply)
                "setScreenBrightness" -> setScreenBrightness((call.argument<Any>("level") as? Number)?.toFloat(), reply)
                "setPreviewPaused" -> session().setPreviewPaused(call.argument<Boolean>("paused") == true, reply)
                "close" -> session().close(reply)
                else -> result.notImplemented()
            }
        } catch (e: CameraError) {
            reply.error(e)
        } catch (e: Exception) {
            reply.error(Codes.INTERNAL, e.toString())
        }
    }

    private fun open(call: MethodCall, reply: Reply) {
        fun int(key: String): Int =
            (call.argument<Any>(key) as? Number)?.toInt()
                ?: throw CameraError(Codes.UNSUPPORTED_CONFIG, "open: missing $key")
        val args = OpenArgs(
            width = int("width"),
            height = int("height"),
            fps = int("fps"),
            codec = Codec.fromWire(call.argument<String>("codec")),
            bitrateBps = int("bitrateBps"),
            ultrawide = call.argument<String>("lens") != "wide",
            segmentDurationMs = (call.argument<Any>("segmentDurationMs") as? Number)?.toLong() ?: 300_000L,
            lockExposure = call.argument<Boolean>("lockExposure") == true,
        )
        // Texture registration must happen on the main thread (we are on it).
        val producer = textures.createSurfaceProducer()
        session().open(args, producer, displayRotationDegrees(), reply)
    }

    private fun displayRotationDegrees(): Int {
        val a = activity
        val rotation = when {
            a == null -> Surface.ROTATION_0
            Build.VERSION.SDK_INT >= 30 -> a.display?.rotation ?: Surface.ROTATION_0
            else -> {
                @Suppress("DEPRECATION")
                a.windowManager.defaultDisplay.rotation
            }
        }
        return Selection.rotationToDegrees(rotation)
    }

    // --- permissions ------------------------------------------------------------

    private fun has(permission: String) =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun permissionState() = mapOf(
        "camera" to has(Manifest.permission.CAMERA),
        "microphone" to has(Manifest.permission.RECORD_AUDIO),
    )

    private fun requestPermissions(reply: Reply) {
        val missing = listOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO).filterNot { has(it) }
        val a = activity
        if (missing.isEmpty() || a == null) {
            reply.success(permissionState())
            return
        }
        // A request already in flight: answer it with the current state.
        pendingPermissions?.success(permissionState())
        pendingPermissions = reply
        a.requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST_CODE)
    }

    /** Android 12+: "Nearby devices" (scan, connect, advertise). Older
     *  versions need location for BLE scanning. */
    private val bluetoothPermissions: List<String>
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            listOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.BLUETOOTH_ADVERTISE,
            )
        } else {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun requestBluetoothPermission(reply: Reply) {
        val missing = bluetoothPermissions.filterNot { has(it) }
        val a = activity
        if (missing.isEmpty() || a == null) {
            reply.success(missing.isEmpty())
            return
        }
        pendingBluetooth?.success(false)
        pendingBluetooth = reply
        a.requestPermissions(missing.toTypedArray(), BLUETOOTH_REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        when (requestCode) {
            PERMISSION_REQUEST_CODE -> {
                pendingPermissions?.success(permissionState())
                pendingPermissions = null
            }
            BLUETOOTH_REQUEST_CODE -> {
                pendingBluetooth?.success(bluetoothPermissions.all { has(it) })
                pendingBluetooth = null
            }
            else -> return false
        }
        return true
    }

    // --- status / window --------------------------------------------------------

    private fun status(): Map<String, Any> {
        val battery = context.getSystemService(BatteryManager::class.java)
        val percent = battery?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
        val charging = battery?.isCharging ?: false
        val thermal = if (Build.VERSION.SDK_INT >= 29) {
            context.getSystemService(PowerManager::class.java)?.currentThermalStatus ?: -1
        } else {
            -1
        }
        val s = session
        val dir = s?.storageDirectory ?: context.filesDir
        val free = try {
            android.os.StatFs(dir.path).availableBytes
        } catch (e: Exception) {
            android.os.StatFs(context.filesDir.path).availableBytes
        }
        return mapOf(
            "batteryPercent" to percent.coerceIn(0, 100),
            "charging" to charging,
            "freeStorageBytes" to free,
            "thermalState" to Selection.thermalState(thermal),
            "recording" to (s?.isRecording ?: false),
        )
    }

    private fun setKeepScreenOn(on: Boolean, reply: Reply) {
        val window = activity?.window
        if (window != null) {
            if (on) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
        reply.success(null)
    }

    /** Overrides this app's screen brightness (0..1), or hands it back to the
     *  system with null. Applies only while this activity is in front. */
    private fun setScreenBrightness(level: Float?, reply: Reply) {
        val window = activity?.window
        if (window != null) {
            val lp = window.attributes
            lp.screenBrightness = level?.coerceIn(0.01f, 1f)
                ?: WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
            window.attributes = lp
        }
        reply.success(null)
    }

    private companion object {
        const val METHOD_CHANNEL = "dev.opensportsball/dual_camera"
        const val EVENT_CHANNEL = "dev.opensportsball/dual_camera/events"
        const val PERMISSION_REQUEST_CODE = 0x5B7C
        const val BLUETOOTH_REQUEST_CODE = 0x5B7D
    }
}
