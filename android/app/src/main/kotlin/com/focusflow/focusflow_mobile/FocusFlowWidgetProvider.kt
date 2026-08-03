package com.focusflow.focusflow_mobile

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject

/**
 * Home-screen widget showing what is due today.
 *
 * HOW IT GETS ITS DATA — the part that decides the whole design:
 *
 * An AppWidgetProvider is a BroadcastReceiver declared by this app, so its code
 * runs in THIS app's process; the launcher only hosts the RemoteViews it returns.
 * That means it can read app-private storage directly, and the obvious-looking
 * alternatives are both worse:
 *
 *  - Calling the API from the widget would need the bearer token out of
 *    flutter_secure_storage, which is Keystore-backed and deliberately awkward to
 *    reach outside the Flutter engine — and would put network latency on a
 *    surface that must draw instantly.
 *  - Spinning up a Flutter engine per update would cost far more than the handful
 *    of strings being displayed.
 *
 * So the app writes a small SNAPSHOT (see HomeWidgetService on the Dart side) and
 * the widget renders it. The widget is therefore always as fresh as the last time
 * the app had the data — which is honest, and is why it renders the snapshot's own
 * timestamp rather than implying it is live.
 */
class FocusFlowWidgetProvider : AppWidgetProvider() {

    companion object {
        const val PREFS = "focusflow_widget"
        const val KEY_PAYLOAD = "payload"

        /** Ask the launcher to redraw every instance of this widget. */
        fun refreshAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val component = android.content.ComponentName(context, FocusFlowWidgetProvider::class.java)
            val ids = manager.getAppWidgetIds(component)
            if (ids.isNotEmpty()) {
                FocusFlowWidgetProvider().onUpdate(context, manager, ids)
            }
        }
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, appWidgetIds: IntArray) {
        for (id in appWidgetIds) {
            manager.updateAppWidget(id, buildViews(context))
        }
    }

    private fun buildViews(context: Context): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.focusflow_widget)

        val raw = context
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_PAYLOAD, null)

        if (raw.isNullOrEmpty()) {
            // Never been populated — the app has not run since the widget was
            // added. Say so plainly instead of showing a convincing "0 tasks".
            views.setTextViewText(R.id.widget_headline, "FocusFlow")
            views.setTextViewText(R.id.widget_subline, "Open the app to sync")
            views.setViewVisibility(R.id.widget_line1, View.GONE)
            views.setViewVisibility(R.id.widget_line2, View.GONE)
            views.setViewVisibility(R.id.widget_line3, View.GONE)
        } else {
            try {
                val json = JSONObject(raw)
                val count = json.optInt("count", 0)
                val titles = json.optJSONArray("titles")

                views.setTextViewText(
                    R.id.widget_headline,
                    if (count == 0) "Nothing due today" else "$count due today",
                )
                views.setTextViewText(R.id.widget_subline, json.optString("updatedLabel", ""))

                val rowIds = intArrayOf(R.id.widget_line1, R.id.widget_line2, R.id.widget_line3)
                for (i in rowIds.indices) {
                    val title = if (titles != null && i < titles.length()) titles.optString(i) else null
                    if (title.isNullOrEmpty()) {
                        views.setViewVisibility(rowIds[i], View.GONE)
                    } else {
                        views.setTextViewText(rowIds[i], "• $title")
                        views.setViewVisibility(rowIds[i], View.VISIBLE)
                    }
                }
            } catch (e: Exception) {
                // A malformed snapshot must not leave a blank rectangle on the
                // home screen with no way to tell what went wrong.
                views.setTextViewText(R.id.widget_headline, "FocusFlow")
                views.setTextViewText(R.id.widget_subline, "Open the app to sync")
                views.setViewVisibility(R.id.widget_line1, View.GONE)
                views.setViewVisibility(R.id.widget_line2, View.GONE)
                views.setViewVisibility(R.id.widget_line3, View.GONE)
            }
        }

        // Whole widget opens the app.
        val launch = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pending = PendingIntent.getActivity(
            context,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        views.setOnClickPendingIntent(R.id.widget_root, pending)

        return views
    }
}
