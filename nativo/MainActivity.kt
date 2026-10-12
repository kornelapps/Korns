package com.kornelapps.kornels_imagenes

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kornels/nativo")
            .setMethodCallHandler { call, result ->
                if (call.method == "libDir") {
                    result.success(applicationInfo.nativeLibraryDir)
                } else {
                    result.notImplemented()
                }
            }
    }
}
