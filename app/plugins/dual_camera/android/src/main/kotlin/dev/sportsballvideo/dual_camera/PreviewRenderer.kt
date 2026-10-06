// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

package dev.sportsballvideo.dual_camera

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Draws camera preview frames, rotated upright for the interface
 * orientation, into the Flutter texture's Surface.
 *
 * Why not hand the Flutter surface to the camera directly: on API 29+ Flutter
 * backs SurfaceProducer with an ImageReader that ignores the buffer
 * transform (handlesCropAndRotation() == false), so frames would show in
 * sensor orientation, and the Dart side (Texture inside an AspectRatio) has no
 * way to rotate them. Rendering through our own SurfaceTexture gives one
 * code path for every backend, and also keeps the camera's preview stream
 * drained while the Flutter surface is gone (app in background), so the
 * recording stream never stalls on a full preview queue.
 *
 * All GL work happens on a dedicated thread.
 */
internal class PreviewRenderer(
    private val bufferSize: Dim,
    private val outputSize: Dim,
    private val displayRotationDeg: Int,
) {
    private val thread = HandlerThread("DualCameraPreview").apply { start() }
    private val handler = Handler(thread.looper)

    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglConfig: EGLConfig? = null
    private var pbuffer: EGLSurface = EGL14.EGL_NO_SURFACE
    private var window: EGLSurface = EGL14.EGL_NO_SURFACE
    private var surfaceTexture: SurfaceTexture? = null
    private var program = 0
    private var texture = 0
    private var aPos = 0
    private var aTex = 0
    private var uSt = 0
    private val stMatrix = FloatArray(16)
    private lateinit var positions: FloatBuffer
    private lateinit var texCoords: FloatBuffer
    @Volatile private var released = false

    /** Surface the camera writes preview frames into. */
    lateinit var cameraSurface: Surface
        private set

    init {
        try {
            runSync(2000) { setUp() }
        } catch (e: Exception) {
            release()
            throw CameraError(Codes.INTERNAL, "Preview renderer setup failed: ${e.message}", e)
        }
    }

    /** Points output at [surface] (or nowhere when null). Asynchronous. */
    fun setOutputSurface(surface: Surface?) {
        handler.post { swapWindow(surface) }
    }

    /** Like [setOutputSurface] but waits (bounded) until done. */
    fun setOutputSurfaceSync(surface: Surface?) {
        try {
            runSync(1000) { swapWindow(surface) }
        } catch (e: Exception) {
            Log.w(TAG, "setOutputSurfaceSync: ${e.message}")
        }
    }

    fun release() {
        if (released) return
        released = true
        handler.post {
            try {
                tearDown()
            } catch (e: Exception) {
                Log.w(TAG, "preview teardown: ${e.message}")
            } finally {
                thread.quitSafely()
            }
        }
    }

    private fun runSync(timeoutMs: Long, block: () -> Unit) {
        val latch = CountDownLatch(1)
        var error: Throwable? = null
        val posted = handler.post {
            try {
                block()
            } catch (t: Throwable) {
                error = t
            } finally {
                latch.countDown()
            }
        }
        if (!posted) throw IllegalStateException("preview thread is gone")
        if (!latch.await(timeoutMs, TimeUnit.MILLISECONDS)) throw IllegalStateException("preview thread timed out")
        error?.let { throw it }
    }

    // --- GL thread below -------------------------------------------------

    private fun setUp() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        check(eglDisplay != EGL14.EGL_NO_DISPLAY) { "no EGL display" }
        val version = IntArray(2)
        check(EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) { "eglInitialize failed" }
        val attribs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        check(EGL14.eglChooseConfig(eglDisplay, attribs, 0, configs, 0, 1, count, 0) && count[0] > 0) {
            "no EGL config"
        }
        eglConfig = configs[0]
        eglContext = EGL14.eglCreateContext(
            eglDisplay, eglConfig, EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
        )
        check(eglContext != EGL14.EGL_NO_CONTEXT) { "eglCreateContext failed" }
        pbuffer = EGL14.eglCreatePbufferSurface(
            eglDisplay, eglConfig, intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0,
        )
        check(pbuffer != EGL14.EGL_NO_SURFACE) { "eglCreatePbufferSurface failed" }
        check(EGL14.eglMakeCurrent(eglDisplay, pbuffer, pbuffer, eglContext)) { "eglMakeCurrent failed" }

        program = buildProgram()
        aPos = GLES20.glGetAttribLocation(program, "aPos")
        aTex = GLES20.glGetAttribLocation(program, "aTex")
        uSt = GLES20.glGetUniformLocation(program, "uSt")

        val tex = IntArray(1)
        GLES20.glGenTextures(1, tex, 0)
        texture = tex[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

        // Triangle strip covering the viewport: BL, BR, TL, TR.
        val corners = arrayOf(0f to 0f, 1f to 0f, 0f to 1f, 1f to 1f)
        val pos = FloatArray(8)
        val tc = FloatArray(8)
        corners.forEachIndexed { i, (gx, gy) ->
            pos[i * 2] = gx * 2f - 1f
            pos[i * 2 + 1] = gy * 2f - 1f
            val (s, t) = Selection.previewTexCoord(gx, gy, displayRotationDeg)
            tc[i * 2] = s
            tc[i * 2 + 1] = t
        }
        positions = floatBuffer(pos)
        texCoords = floatBuffer(tc)

        val st = SurfaceTexture(texture)
        st.setDefaultBufferSize(bufferSize.width, bufferSize.height)
        st.setOnFrameAvailableListener({ drawFrame() }, handler)
        surfaceTexture = st
        cameraSurface = Surface(st)
    }

    private fun swapWindow(surface: Surface?) {
        if (released || eglDisplay == EGL14.EGL_NO_DISPLAY) return
        if (window != EGL14.EGL_NO_SURFACE) {
            EGL14.eglMakeCurrent(eglDisplay, pbuffer, pbuffer, eglContext)
            EGL14.eglDestroySurface(eglDisplay, window)
            window = EGL14.EGL_NO_SURFACE
        }
        if (surface == null || !surface.isValid) return
        val w = EGL14.eglCreateWindowSurface(eglDisplay, eglConfig, surface, intArrayOf(EGL14.EGL_NONE), 0)
        if (w == null || w == EGL14.EGL_NO_SURFACE) {
            Log.w(TAG, "eglCreateWindowSurface failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
            return
        }
        window = w
        if (EGL14.eglMakeCurrent(eglDisplay, window, window, eglContext)) {
            // Never block the GL thread waiting for Flutter to consume a frame;
            // a blocked preview would back up into the camera and drop
            // recorded frames.
            EGL14.eglSwapInterval(eglDisplay, 0)
        }
    }

    private fun drawFrame() {
        val st = surfaceTexture ?: return
        if (released) return
        val target = if (window != EGL14.EGL_NO_SURFACE) window else pbuffer
        if (!EGL14.eglMakeCurrent(eglDisplay, target, target, eglContext)) {
            Log.w(TAG, "eglMakeCurrent failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
            if (target == window) swapWindow(null)
            // Still consume the frame so the camera keeps flowing.
            EGL14.eglMakeCurrent(eglDisplay, pbuffer, pbuffer, eglContext)
            try { st.updateTexImage() } catch (e: Exception) { /* abandoned */ }
            return
        }
        try {
            st.updateTexImage()
        } catch (e: Exception) {
            Log.w(TAG, "updateTexImage: ${e.message}")
            return
        }
        if (target != window) return
        st.getTransformMatrix(stMatrix)
        GLES20.glViewport(0, 0, outputSize.width, outputSize.height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
        GLES20.glUniformMatrix4fv(uSt, 1, false, stMatrix, 0)
        GLES20.glEnableVertexAttribArray(aPos)
        GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 0, positions)
        GLES20.glEnableVertexAttribArray(aTex)
        GLES20.glVertexAttribPointer(aTex, 2, GLES20.GL_FLOAT, false, 0, texCoords)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(aPos)
        GLES20.glDisableVertexAttribArray(aTex)
        if (!EGL14.eglSwapBuffers(eglDisplay, window)) {
            Log.w(TAG, "eglSwapBuffers failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
            swapWindow(null)
        }
    }

    private fun tearDown() {
        surfaceTexture?.setOnFrameAvailableListener(null)
        if (this::cameraSurface.isInitialized) cameraSurface.release()
        surfaceTexture?.release()
        surfaceTexture = null
        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (window != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, window)
            if (pbuffer != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, pbuffer)
            if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
            // No eglTerminate: the default display is shared with Flutter's own
            // renderer in this process.
            EGL14.eglReleaseThread()
        }
        window = EGL14.EGL_NO_SURFACE
        pbuffer = EGL14.EGL_NO_SURFACE
        eglContext = EGL14.EGL_NO_CONTEXT
        eglDisplay = EGL14.EGL_NO_DISPLAY
    }

    private fun buildProgram(): Int {
        val vs = compile(GLES20.GL_VERTEX_SHADER, VERTEX_SHADER)
        val fs = compile(GLES20.GL_FRAGMENT_SHADER, FRAGMENT_SHADER)
        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, vs)
        GLES20.glAttachShader(p, fs)
        GLES20.glLinkProgram(p)
        val status = IntArray(1)
        GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, status, 0)
        check(status[0] == GLES20.GL_TRUE) { "link failed: ${GLES20.glGetProgramInfoLog(p)}" }
        GLES20.glDeleteShader(vs)
        GLES20.glDeleteShader(fs)
        return p
    }

    private fun compile(type: Int, src: String): Int {
        val s = GLES20.glCreateShader(type)
        GLES20.glShaderSource(s, src)
        GLES20.glCompileShader(s)
        val status = IntArray(1)
        GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, status, 0)
        check(status[0] == GLES20.GL_TRUE) { "shader compile failed: ${GLES20.glGetShaderInfoLog(s)}" }
        return s
    }

    private fun floatBuffer(values: FloatArray): FloatBuffer =
        ByteBuffer.allocateDirect(values.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
            put(values)
            position(0)
        }

    private companion object {
        const val VERTEX_SHADER = """
            uniform mat4 uSt;
            attribute vec4 aPos;
            attribute vec4 aTex;
            varying vec2 vTex;
            void main() {
                gl_Position = aPos;
                vTex = (uSt * aTex).xy;
            }
        """
        const val FRAGMENT_SHADER = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTex;
            uniform samplerExternalOES sTex;
            void main() {
                gl_FragColor = texture2D(sTex, vTex);
            }
        """
    }
}
