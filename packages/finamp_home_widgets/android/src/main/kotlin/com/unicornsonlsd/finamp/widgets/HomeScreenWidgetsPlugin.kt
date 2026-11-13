package com.unicornsonlsd.finamp.widgets

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/**
 * Receives what is playing from lib/services/home_screen_widgets.dart.
 *
 * A plugin (rather than a channel set up in MainActivity) so it is attached to every Flutter engine, including
 * the one audio_service starts without the activity: when music is started from a widget, the notification or
 * Android Auto with the app closed. Without it, the widgets missed those updates and showed a stale track.
 */
class HomeScreenWidgetsPlugin : FlutterPlugin {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.unicornsonlsd.finamp/home_screen_widgets").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "update" -> {
                        NowPlayingWidgets.updateInBackground(context, NowPlayingState.fromMap(call.arguments as? Map<*, *>))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }
}
