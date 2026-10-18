package com.streaksaver.streak_saver

import android.app.ActivityManager
import android.app.AlarmManager
import android.app.AppOpsManager
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.os.Process
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Finds and opens the settings that can stop the daily background send.
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "streak_saver/blockers")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "check" -> result.success(blockers())
                    "fix" -> result.success(fix(call.arguments as String))
                    else -> result.notImplemented()
                }
            }
    }

    private val isMiui get() = !prop("ro.miui.ui.version.name").isNullOrEmpty()

    /** Names of blockers that are currently active. */
    private fun blockers(): List<String> {
        val out = mutableListOf<String>()
        val pm = getSystemService(PowerManager::class.java)
        if (!pm.isIgnoringBatteryOptimizations(packageName)) out += "battery"
        if (Build.VERSION.SDK_INT >= 28 &&
            getSystemService(ActivityManager::class.java).isBackgroundRestricted) out += "background"
        if (Build.VERSION.SDK_INT >= 31 &&
            !getSystemService(AlarmManager::class.java).canScheduleExactAlarms()) out += "alarm"
        if (isMiui && miuiAutostartDenied()) out += "autostart"
        return out
    }

    // MIUI keeps autostart in a private app-op (10008); 0 = allowed. Unknown counts as allowed.
    private fun miuiAutostartDenied(): Boolean = try {
        val ops = getSystemService(AppOpsManager::class.java)
        val m = AppOpsManager::class.java.getMethod(
            "checkOpNoThrow", Int::class.java, Int::class.java, String::class.java)
        (m.invoke(ops, 10008, Process.myUid(), packageName) as Int) != AppOpsManager.MODE_ALLOWED
    } catch (_: Exception) {
        false
    }

    private fun fix(which: String): Boolean {
        val pkg = Uri.parse("package:$packageName")
        val intents = when (which) {
            // On MIUI the standard request opens an app chooser; its own page is clearer.
            // Its "No restrictions" also clears Android's battery optimization.
            "battery" -> (if (isMiui) listOf(Intent().setComponent(ComponentName(
                "com.miui.powerkeeper", "com.miui.powerkeeper.ui.HiddenAppsConfigActivity"))
                .putExtra("package_name", packageName)
                .putExtra("package_label", packageManager.getApplicationLabel(applicationInfo).toString()))
                else emptyList()) + listOf(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, pkg),
                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            "alarm" -> listOf(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, pkg))
            "autostart" -> listOf(Intent().setComponent(ComponentName(
                "com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity")))
            else -> emptyList()
        } + Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkg) // always-works fallback
        for (i in intents) {
            try {
                startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (_: Exception) {
            }
        }
        return false
    }

    private fun prop(key: String): String? = try {
        Class.forName("android.os.SystemProperties")
            .getMethod("get", String::class.java).invoke(null, key) as String
    } catch (_: Exception) {
        null
    }
}
