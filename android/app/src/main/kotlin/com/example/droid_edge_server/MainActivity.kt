package com.example.droid_edge_server

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val REQUEST_CODE_PICK_LITERTLM = 4109
    }

    private var liteRtLmBridge: LiteRtLmBridge? = null
    private var pendingPickResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.example.droid_edge_server/telemetry",
        ).setMethodCallHandler { call, result ->
            if (call.method == "getThermalTelemetry") {
                result.success(
                    mapOf(
                        "thermalStatus" to readThermalStatus(),
                        "batteryTemperatureC" to readBatteryTemperatureC(),
                    ),
                )
            } else {
                result.notImplemented()
            }
        }

        val bridge = liteRtLmBridge ?: LiteRtLmBridge(this).also { liteRtLmBridge = it }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            LiteRtLmBridge.CHANNEL_NAME,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(true)
                "getDeviceRamGb" -> result.success(bridge.getDeviceRamGb())
                "getModelsDirectory" -> result.success(bridge.getModelsDirectory())
                "runInference" -> {
                    val prompt = call.argument<String>("prompt")
                    val modelPath = call.argument<String>("modelPath")
                    val forceJson = call.argument<Boolean>("forceJson") ?: false
                    if (prompt.isNullOrBlank() || modelPath.isNullOrBlank()) {
                        result.error(
                            "INVALID_ARGS",
                            "Both \"prompt\" and \"modelPath\" must be non-empty strings.",
                            null,
                        )
                    } else {
                        bridge.runInference(
                            prompt = prompt,
                            modelPath = modelPath,
                            forceJson = forceJson,
                            onSuccess = { text -> result.success(text) },
                            onError = { code, message -> result.error(code, message, null) },
                        )
                    }
                }
                "cancelInference" -> {
                    bridge.cancelInference()
                    result.success(null)
                }
                "unloadModel", "dispose" -> {
                    bridge.unloadModel { result.success(null) }
                }
                "pickModelFile" -> {
                    if (pendingPickResult != null) {
                        result.error(
                            "PICKER_BUSY",
                            "A model file selection dialog is already open.",
                            null,
                        )
                    } else {
                        pendingPickResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                        }
                        try {
                            @Suppress("DEPRECATION")
                            startActivityForResult(intent, REQUEST_CODE_PICK_LITERTLM)
                        } catch (error: Throwable) {
                            pendingPickResult = null
                            result.error(
                                "PICKER_UNAVAILABLE",
                                error.message ?: "No document picker available on this device.",
                                null,
                            )
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_CODE_PICK_LITERTLM) {
            val result = pendingPickResult
            pendingPickResult = null
            if (result == null) return

            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) {
                result.success(null)
                return
            }

            val bridge = liteRtLmBridge
            if (bridge == null) {
                result.error("BRIDGE_DISPOSED", "LiteRT-LM bridge is not active.", null)
                return
            }
            bridge.importModelUri(
                uri = uri,
                onSuccess = { path -> result.success(path) },
                onError = { code, message -> result.error(code, message, null) },
            )
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        pendingPickResult = null
        liteRtLmBridge?.dispose()
        liteRtLmBridge = null
        super.onDestroy()
    }

    private fun readThermalStatus(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return "unknown"
        }
        val powerManager =
            getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return "unknown"
        return when (powerManager.currentThermalStatus) {
            PowerManager.THERMAL_STATUS_NONE -> "none"
            PowerManager.THERMAL_STATUS_LIGHT -> "light"
            PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
            PowerManager.THERMAL_STATUS_SEVERE -> "severe"
            PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
            PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
            PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
            else -> "unknown"
        }
    }

    private fun readBatteryTemperatureC(): Double? {
        val intent = registerReceiver(
            null,
            IntentFilter(Intent.ACTION_BATTERY_CHANGED),
        ) ?: return null
        val tenthsOfCelsius = intent.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
        if (tenthsOfCelsius == Int.MIN_VALUE) {
            return null
        }
        return tenthsOfCelsius / 10.0
    }
}
