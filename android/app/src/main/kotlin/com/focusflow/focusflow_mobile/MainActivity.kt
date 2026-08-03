package com.focusflow.focusflow_mobile

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Receives text shared into the app from the Android share sheet and hands it to
 * Dart over a method channel.
 *
 * Written by hand rather than pulled in as a package: this is about thirty lines,
 * and the usual alternative (receive_sharing_intent) is a dependency with a
 * history of breaking changes, in a project that deliberately avoids codegen and
 * keeps its dependency list short.
 *
 * Two arrival paths, and both matter:
 *  - COLD START: the share launches the process. Dart is not listening yet, so
 *    the text is held in [pendingSharedText] and Dart pulls it with
 *    `getInitialSharedText` once it is ready. Pushing at this point would go
 *    nowhere and the share would be silently lost.
 *  - ALREADY RUNNING: the activity is launchMode="singleTop", so the share
 *    arrives at [onNewIntent] and is pushed straight to Dart rather than
 *    starting a second copy of the app with its own empty state.
 */
class MainActivity : FlutterActivity() {

    private val channelName = "focusflow/share"
    private val widgetChannelName = "focusflow/widget"
    private var channel: MethodChannel? = null

    /** Text that arrived before Dart was listening. Consumed exactly once. */
    private var pendingSharedText: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialSharedText" -> {
                        // Cleared on read: otherwise every hot restart during
                        // development would re-open the editor with a task the
                        // user already created.
                        val text = pendingSharedText
                        pendingSharedText = null
                        result.success(text)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        // Home-screen widget: Dart hands over a small snapshot, which is written
        // to SharedPreferences and then rendered by FocusFlowWidgetProvider. The
        // widget never talks to the network — see that class for why.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, widgetChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "updateWidget" -> {
                        val payload = call.arguments as? String
                        getSharedPreferences(FocusFlowWidgetProvider.PREFS, MODE_PRIVATE)
                            .edit()
                            .putString(FocusFlowWidgetProvider.KEY_PAYLOAD, payload)
                            .apply()
                        FocusFlowWidgetProvider.refreshAll(applicationContext)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // The launch intent exists before Dart starts, so stash it now.
        pendingSharedText = extractSharedText(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Keep getIntent() in step, or a later cold-path read would see the
        // original launch intent instead of this one.
        setIntent(intent)

        val text = extractSharedText(intent) ?: return
        val sink = channel
        if (sink != null) {
            sink.invokeMethod("sharedText", text)
        } else {
            // Engine not attached yet — hold it rather than drop the share.
            pendingSharedText = text
        }
    }

    private fun extractSharedText(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_SEND) return null
        if (intent.type?.startsWith("text/") != true) return null

        // EXTRA_TEXT is the body. EXTRA_SUBJECT is often the page title when a
        // browser shares a link, which makes a far better task title than the
        // bare URL — so keep both, subject first.
        val body = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)?.trim()
        return when {
            !subject.isNullOrEmpty() && !body.isNullOrEmpty() -> "$subject\n$body"
            !body.isNullOrEmpty() -> body
            !subject.isNullOrEmpty() -> subject
            else -> null
        }
    }
}
