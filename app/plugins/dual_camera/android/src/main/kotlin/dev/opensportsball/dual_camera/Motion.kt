// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

package dev.opensportsball.dual_camera

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Keeps the motion sensors running for the `motion` method and sums up each
 * window between calls: up (averaged gravity, as [Gravity] reports it), the
 * fastest rotation (gyroscope) and the largest acceleration apart from
 * gravity (linear acceleration sensor). The first call starts the sensors
 * and returns an empty window. Main thread only.
 */
internal class Motion(private val context: Context, private val main: Handler) {
    private var running = false
    private var n = 0
    private val sum = FloatArray(3)
    private var maxRotation = 0f // rad/s
    private var maxAcceleration = 0f // m/s^2
    private var hasGyro = false
    private var hasLinear = false

    private val listener = object : SensorEventListener {
        override fun onSensorChanged(e: SensorEvent) {
            val v = e.values
            when (e.sensor.type) {
                Sensor.TYPE_GRAVITY, Sensor.TYPE_ACCELEROMETER -> {
                    for (i in 0..2) sum[i] += v[i]
                    n++
                }
                Sensor.TYPE_GYROSCOPE -> maxRotation = max(maxRotation, sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]))
                Sensor.TYPE_LINEAR_ACCELERATION ->
                    maxAcceleration = max(maxAcceleration, sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]))
            }
        }

        override fun onAccuracyChanged(s: Sensor?, accuracy: Int) {}
    }

    fun take(displayRotationDeg: Int): Map<String, Any> {
        if (!running) {
            start()
            return mapOf("samples" to 0)
        }
        val window = mutableMapOf<String, Any>("samples" to n)
        if (n > 0) {
            val (x, y, z) = Selection.upInDisplay(sum[0], sum[1], sum[2], displayRotationDeg)
            val len = sqrt(x * x + y * y + z * z)
            if (len > 0f) {
                window["up"] = mapOf("x" to (x / len).toDouble(), "y" to (y / len).toDouble(), "z" to (z / len).toDouble())
            }
            if (hasGyro) window["maxRotationDegPerS"] = Math.toDegrees(maxRotation.toDouble())
            if (hasLinear) window["maxAccelerationG"] = maxAcceleration / SensorManager.GRAVITY_EARTH.toDouble()
        }
        reset()
        return window
    }

    fun stop() {
        if (!running) return
        context.getSystemService(SensorManager::class.java)?.unregisterListener(listener)
        running = false
    }

    private fun start() {
        val sm = context.getSystemService(SensorManager::class.java) ?: return
        running = true
        reset()
        val gravity = sm.getDefaultSensor(Sensor.TYPE_GRAVITY) ?: sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        val gyro = sm.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
        val linear = sm.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)
        hasGyro = gyro != null
        hasLinear = linear != null
        for (s in listOfNotNull(gravity, gyro, linear)) {
            sm.registerListener(listener, s, SensorManager.SENSOR_DELAY_GAME, main)
        }
    }

    private fun reset() {
        n = 0
        sum.fill(0f)
        maxRotation = 0f
        maxAcceleration = 0f
    }
}
