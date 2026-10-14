package com.micahmo.sports

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Rational
import android.view.Display
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    // ---- One app across the phone and the car ----
    // Android Auto opens the app on the car with a fresh activity (it clears
    // the task), so the app's state lives in an engine that outlives the
    // activity: open it on the car while it plays on the phone and it carries
    // on there. Opening it on the phone just moves the activity back.
    companion object {
        private const val ENGINE_ID = "main"
        private val handler = Handler(Looper.getMainLooper())
        private var pendingDestroy: Runnable? = null
        // The activity using the engine now. The one the car replaces is
        // destroyed after its replacement starts, and mustn't end the app.
        private var host: MainActivity? = null
        // Unplugging closes the activity on the car. The app waits this long
        // (stopped, as when sent to the background) for the phone to open it,
        // which picks the stream up at live; leaving it ends it at once.
        private const val UNPLUGGED_KEEP_MS = 30 * 60 * 1000L
    }

    private var engineReused = false

    override fun provideFlutterEngine(context: Context): FlutterEngine {
        host = this
        pendingDestroy?.let { handler.removeCallbacks(it) }
        pendingDestroy = null
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let {
            engineReused = true
            return it
        }
        val engine = FlutterEngine(context.applicationContext)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    // ---- Channels ----
    private val pipChannelName = "pip"
    private val nowPlayingChannelName = "nowplaying"
    private val carChannelName = "car"

    private lateinit var pipChannel: MethodChannel
    private lateinit var nowPlayingChannel: MethodChannel
    private lateinit var carChannel: MethodChannel

    // ---- Android Auto: on the car's screen rather than the phone's ----
    private var onCar: Boolean? = null

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

        // ------ Car channel: which screen the app is on ------
        carChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, carChannelName)
        carChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isOnCar" -> result.success(isOnCar())
                else -> result.notImplemented()
            }
        }
        // The app carried over from the other screen: tell it where it is now.
        if (engineReused) carChannel.invokeMethod("attached", isOnCar())
    }

    // The car's display this activity is on, if it is (see onDestroy).
    private var carDisplayId: Int? = null

    private fun carDisplayGone(id: Int): Boolean =
        (getSystemService(Context.DISPLAY_SERVICE) as DisplayManager).getDisplay(id) == null

    // Android Auto runs this activity on its own display, not the phone's.
    private fun isOnCar(): Boolean {
        val d = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display else @Suppress("DEPRECATION") windowManager.defaultDisplay
        val car = d != null && d.displayId != Display.DEFAULT_DISPLAY
        if (car) carDisplayId = d!!.displayId
        return car
    }

    // Moving between the phone and the car is a configuration change (the
    // activity keeps running), so tell the app here.
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        val now = isOnCar()
        // Opened on the phone while the car is still there: no longer on it.
        // (Unplugging moves it here too, but by then the car's display is gone.)
        if (!now) carDisplayId?.let { if (!carDisplayGone(it)) carDisplayId = null }
        if (now != onCar && ::carChannel.isInitialized) {
            onCar = now
            carChannel.invokeMethod("onCarChanged", now)
        }
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
        // Not on a car's screen: Android Auto has no picture-in-picture.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && autoPipEnabled && !isInPictureInPictureMode && !isOnCar()) {
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
            .setContentTitle("Watching live")
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
        // Leaving the app (back, or swiped away) ends it as before. Moving to
        // the car finishes this activity too, but a new one takes the engine
        // straight away, which calls this off.
        if (isFinishing && host === this) {
            host = null
            val unplugged = carDisplayId?.let { carDisplayGone(it) } == true
            val r = Runnable {
                pendingDestroy = null
                FlutterEngineCache.getInstance().get(ENGINE_ID)?.destroy()
                FlutterEngineCache.getInstance().remove(ENGINE_ID)
            }
            pendingDestroy = r
            handler.postDelayed(r, if (unplugged) UNPLUGGED_KEEP_MS else 3000)
        }
    }
}
