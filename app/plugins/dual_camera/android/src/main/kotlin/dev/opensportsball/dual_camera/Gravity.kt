// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

package dev.opensportsball.dual_camera

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import kotlin.math.sqrt

/**
 * Reads which way is up, for the `orientation` method: averages a few
 * gravity sensor samples (the accelerometer if there is none) and replies
 * with a unit vector in the displayed picture's axes, or null.
 */
internal object Gravity {
    private const val SAMPLES = 10
    private const val TIMEOUT_MS = 1000L

    fun read(context: Context, displayRotationDeg: Int, main: Handler, reply: Reply) {
        val sm = context.getSystemService(SensorManager::class.java)
        val sensor = sm?.getDefaultSensor(Sensor.TYPE_GRAVITY)
            ?: sm?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        if (sm == null || sensor == null) {
            reply.success(null)
            return
        }
        val sum = FloatArray(3)
        var n = 0
        lateinit var listener: SensorEventListener
        val finish = Runnable {
            sm.unregisterListener(listener)
            reply.success(if (n == 0) null else result(sum, displayRotationDeg))
        }
        listener = object : SensorEventListener {
            override fun onSensorChanged(e: SensorEvent) {
                if (reply.isDone) return
                for (i in 0..2) sum[i] += e.values[i]
                if (++n >= SAMPLES) {
                    main.removeCallbacks(finish)
                    finish.run()
                }
            }

            override fun onAccuracyChanged(s: Sensor?, accuracy: Int) {}
        }
        sm.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_GAME, main)
        main.postDelayed(finish, TIMEOUT_MS)
    }

    private fun result(sum: FloatArray, displayRotationDeg: Int): Map<String, Double>? {
        val (x, y, z) = Selection.upInDisplay(sum[0], sum[1], sum[2], displayRotationDeg)
        val len = sqrt(x * x + y * y + z * z)
        if (len == 0f) return null
        return mapOf("x" to (x / len).toDouble(), "y" to (y / len).toDouble(), "z" to (z / len).toDouble())
    }
}
