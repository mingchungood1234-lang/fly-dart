package com.example.flutterapiuitest

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel


class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.flutterapiuitest/screen_share"
    private var pendingResult: MethodChannel.Result? = null
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isScreenSharingSupported" -> {
                    result.success(true)
                }
                "requestScreenCapture" -> {
                    requestScreenCapture(result)
                }
                "startForegroundService" -> {
                    val resultCode = call.argument<Int>("resultCode")
                    val data = call.argument<String>("data")
                    
                    if (resultCode != null && data != null) {
                        val intent = Intent(this, ScreenShareService::class.java).apply {
                            action = ScreenShareService.ACTION_START
                            putExtra("resultCode", resultCode)
                            putExtra("data", data)
                        }
                        
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGS", "Missing resultCode or data", null)
                    }
                }
                "stopForegroundService" -> {
                    val intent = Intent(this, ScreenShareService::class.java).apply {
                        action = ScreenShareService.ACTION_STOP
                    }
                    startService(intent)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
    
    private fun requestScreenCapture(result: MethodChannel.Result) {
        pendingResult = result
        try {
            val mediaProjectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            startActivityForResult(mediaProjectionManager.createScreenCaptureIntent(), REQUEST_MEDIA_PROJECTION)
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
            pendingResult = null
        }
    }
    
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_MEDIA_PROJECTION) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                // Pass the result code and data back to Flutter
                pendingResult?.success(mapOf(
                    "resultCode" to resultCode,
                    "dataString" to data.toUri(0)
                ))
            } else {
                pendingResult?.error("DENIED", "Screen capture permission denied", null)
            }
            pendingResult = null
        }
    }
    
    companion object {
        private const val REQUEST_MEDIA_PROJECTION = 1001
    }
}
