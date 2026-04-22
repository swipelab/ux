package io.swipelab.ux

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding

interface NativePlugin {
    fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
    fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
    fun onAttachedToActivity(binding: ActivityPluginBinding) {}
    fun onDetachedFromActivity() {}
    fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
}
