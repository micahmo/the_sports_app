package com.micahmo.sports

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "pip"
    private lateinit var channel: MethodChannel
    private var autoPipEnabled: Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "enterPip" -> {
                    val width = call.argument<Int>("width") ?: 16
                    val height = call.argument<Int>("height") ?: 9
                    enterPip(width, height)
                    result.success(true)
                }
                "isInPip" -> result.success(isInPictureInPictureMode)
                "setAutoPipOnUserLeave" -> {
                    autoPipEnabled = call.argument<Boolean>("enabled") == true
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun enterPip(w: Int, h: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val params: PictureInPictureParams = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(w, h))
                .apply {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        setAutoEnterEnabled(false) // never OS-auto, we control it
                    }
                }
                .build()
            enterPictureInPictureMode(params)
        } else {
            @Suppress("DEPRECATION")
            enterPictureInPictureMode()
        }
    }

    // Auto-enter PiP ONLY if the player screen asked for it.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && autoPipEnabled && !isInPictureInPictureMode) {
            enterPip(16, 9)
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration?
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        if (::channel.isInitialized) {
            channel.invokeMethod("pipChanged", mapOf("inPip" to isInPictureInPictureMode))
        }
    }
}
