// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

package dev.opensportsball.opensportsball

import android.content.Context
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Uses one Flutter engine for the life of the process instead of one per
 * activity, so the upload queue (in Dart) keeps running after the app is
 * swiped away while [UploadKeepAliveService] holds the process.
 */
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        mainEngine(this)
        BackgroundUploadChannel.activity = this
        super.onCreate(savedInstanceState)
    }

    override fun onDestroy() {
        if (BackgroundUploadChannel.activity === this) BackgroundUploadChannel.activity = null
        super.onDestroy()
    }

    override fun getCachedEngineId(): String = ENGINE_ID

    // A cached engine is never destroyed with the activity.
    override fun shouldDestroyEngineWithHost(): Boolean = false

    companion object {
        private const val ENGINE_ID = "main"

        fun mainEngine(context: Context): FlutterEngine {
            FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
            val engine = FlutterEngine(context.applicationContext)
            BackgroundUploadChannel(context.applicationContext).register(engine)
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
            return engine
        }
    }
}
