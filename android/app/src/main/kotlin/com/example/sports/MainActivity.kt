package com.micahmo.sports

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.util.Rational
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    // ---- Channels ----
    private val pipChannelName = "pip"
    private val nowPlayingChannelName = "nowplaying"

    private lateinit var pipChannel: MethodChannel
    private lateinit var nowPlayingChannel: MethodChannel

    // ---- PiP state ----
    private var autoPipEnabled: Boolean = false

    // ---- Notification constants ----
    private val NOW_PLAYING_CHANNEL_ID = "now_playing_channel"
    private val NOW_PLAYING_NOTIFICATION_ID = 1001

    // override fun onCreate(savedInstanceState: Bundle?) {
    //     super.onCreate(savedInstanceState)
    //     // Hide contents in Android's app switcher for privacy
    //     window.setFlags(
    //         WindowManager.LayoutParams.FLAG_SECURE,
    //         WindowManager.LayoutParams.FLAG_SECURE
    //     )
    // }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ------ PiP channel ------
        pipChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pipChannelName)
        pipChannel.setMethodCallHandler { call, result ->
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

        // ------ Now Playing notification channel ------
        nowPlayingChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, nowPlayingChannelName)
        nowPlayingChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "show" -> {
                    val title = call.argument<String>("title") ?: "Watching stream"
                    showNowPlaying(title)
                    result.success(true)
                }
                "hide" -> {
                    hideNowPlaying()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        ensureNowPlayingChannel()
    }

    // ---- PiP helpers ----
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
        if (::pipChannel.isInitialized) {
            pipChannel.invokeMethod("pipChanged", mapOf("inPip" to isInPictureInPictureMode))
        }
    }

    // ---- Now Playing notification helpers ----
    private fun ensureNowPlayingChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val chan = NotificationChannel(
                NOW_PLAYING_CHANNEL_ID,
                "Now Playing",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Active stream"
                setShowBadge(false)
            }
            nm.createNotificationChannel(chan)
        }
    }

    private fun showNowPlaying(title: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        // Tap → bring app to foreground
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        else PendingIntent.FLAG_UPDATE_CURRENT
        val contentIntent = PendingIntent.getActivity(this, 0, launchIntent, flags)

        val notification: Notification = NotificationCompat.Builder(this, NOW_PLAYING_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher) // replace if you have a better small icon
            .setContentTitle("Sports")
            .setContentText(title)
            .setContentIntent(contentIntent)
            .setOngoing(true)          // persistent until you cancel
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        nm.notify(NOW_PLAYING_NOTIFICATION_ID, notification)
    }

    private fun hideNowPlaying() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(NOW_PLAYING_NOTIFICATION_ID)
    }

    override fun onDestroy() {
        // Safety: remove if app/engine is being destroyed
        hideNowPlaying()
        super.onDestroy()
    }
}
