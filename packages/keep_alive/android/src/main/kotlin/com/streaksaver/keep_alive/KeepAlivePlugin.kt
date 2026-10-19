package com.streaksaver.keep_alive

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

// The alarm plugin reports its job done as soon as the Dart callback starts, so Android
// sees an "empty" process and kills it minutes into a run (seen: 6.5 min, after person #1).
// A foreground service for the length of the run keeps the process alive.
class KeepAlivePlugin : FlutterPlugin {
    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        val ctx = b.applicationContext
        MethodChannel(b.binaryMessenger, "streak_saver/keep_alive").setMethodCallHandler { call, result ->
            val i = Intent(ctx, KeepAliveService::class.java)
            try {
                when (call.method) {
                    "start" -> if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
                    "stop" -> ctx.stopService(i)
                }
                result.success(null)
            } catch (e: Exception) { // e.g. Android 12+ refusing a background start
                result.error("keep_alive", e.toString(), null)
            }
        }
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {}
}

class KeepAliveService : Service() {
    override fun onBind(i: Intent?): IBinder? = null

    override fun onStartCommand(i: Intent?, flags: Int, startId: Int): Int {
        val n = if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel("run", "Sending streaks", NotificationManager.IMPORTANCE_LOW))
            Notification.Builder(this, "run")
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("Sending streaks…")
            .build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else startForeground(1, n)
        return START_NOT_STICKY
    }
}
