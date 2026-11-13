package todo.app

import android.app.Activity
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Paint
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.View
import android.widget.ArrayAdapter
import android.widget.ListView
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONArray
import org.json.JSONObject

/**
 * Виджет списка задач, по образцу Microsoft To Do.
 *
 * Данные готовит приложение (Dart): в общих настройках home_widget лежит «снимок» — разделы,
 * списки и их открытые задачи. Здесь он только отображается. Отметка выполнения уходит
 * в фоновый обработчик Dart (та же логика, что в приложении: права, регулярные задачи, синхронизация).
 */
object WidgetData {
    const val SNAPSHOT = "snapshot"
    const val EXTRA_ACTION = "todo_action"
    const val EXTRA_TASK = "todo_task"
    const val HOLD_UNTIL = "widget_hold_until"

    /** Сколько после нажатия на галочку список не перестраивается. */
    private const val HOLD_MS = 3 * 60 * 1000L

    fun holdOrder(context: Context) {
        prefs(context).edit().putLong(HOLD_UNTIL, System.currentTimeMillis() + HOLD_MS).commit()
    }

    fun prefs(context: Context): SharedPreferences = HomeWidgetPlugin.getData(context)

    fun snapshot(context: Context): JSONObject =
        try { JSONObject(prefs(context).getString(SNAPSHOT, null) ?: "{}") } catch (e: Exception) { JSONObject() }

    /** Разделы и списки: пары «id — название». Без снимка (приложение ещё не открывали) — стандартные разделы. */
    fun lists(context: Context): List<Pair<String, String>> {
        val arr = snapshot(context).optJSONArray("lists") ?: JSONArray()
        val out = ArrayList<Pair<String, String>>()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            out.add(o.optString("id") to o.optString("name"))
        }
        if (out.isEmpty()) {
            out.add("today" to "Сегодняшний день")
            out.add("important" to "Важные")
            out.add("schedule" to "Планирование")
            out.add("tasks" to "Задачи")
            out.add("private" to "Мои дела")
        }
        return out
    }

    /**
     * Оформление из настроек приложения. Цвет, который пользователь не задал, равен null:
     * тогда остаётся цвет из ресурсов (палитра системы, светлая или тёмная тема).
     */
    class Style(val bg: Int?, val border: Int?, val text: Int?, val accent: Int?, val alpha: Int) {
        /** Приглушённый текст (сроки, закрытые задачи, галочки) — тот же цвет текста, но прозрачнее. */
        val muted: Int? get() = text?.let { (it and 0x00FFFFFF) or (0x99 shl 24) }
    }

    fun style(context: Context): Style {
        val o = snapshot(context).optJSONObject("style") ?: JSONObject()
        fun color(key: String): Int? =
            try { o.optString(key).takeIf { it.isNotEmpty() }?.let { android.graphics.Color.parseColor(it) } } catch (e: Exception) { null }
        return Style(color("bg"), color("border"), color("text"), color("accent"), o.optInt("alpha", 100).coerceIn(0, 100) * 255 / 100)
    }

    /** Раздел виджета; прежний раздел «Запланировано» заменило «Планирование» (только сегодняшний день). */
    fun listOf(context: Context, widgetId: Int): String =
        (prefs(context).getString("widget_list_$widgetId", "today") ?: "today").let { if (it == "planned") "schedule" else it }

    fun tasks(context: Context, listId: String): JSONArray =
        snapshot(context).optJSONObject("tasks")?.optJSONArray(listId) ?: JSONArray()

    /**
     * Сразу показать нажатие: задача в снимке отмечается закрытой (или снова открытой) на своём месте,
     * не дожидаясь фонового обработчика. Когда он отработает, приложение пришлёт новый снимок
     * и закрытая задача уйдёт в конец списка.
     */
    fun markDone(context: Context, taskId: String, done: Boolean) {
        val snap = snapshot(context)
        val all = snap.optJSONObject("tasks") ?: return
        val keys = all.keys()
        while (keys.hasNext()) {
            val rows = all.optJSONArray(keys.next()) ?: continue
            for (i in 0 until rows.length()) {
                val o = rows.optJSONObject(i) ?: continue
                if (o.optString("id") == taskId) o.put("done", done)
            }
        }
        prefs(context).edit().putString(SNAPSHOT, snap.toString()).commit()
    }

    fun refreshAll(context: Context) {
        val mgr = AppWidgetManager.getInstance(context)
        val ids = mgr.getAppWidgetIds(ComponentName(context, TodoWidgetProvider::class.java))
        @Suppress("DEPRECATION")
        mgr.notifyAppWidgetViewDataChanged(ids, R.id.widget_list)
    }
}

class TodoWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray, widgetData: SharedPreferences) {
        val style = WidgetData.style(context)
        for (id in appWidgetIds) {
            val listId = WidgetData.listOf(context, id)
            val name = WidgetData.lists(context).firstOrNull { it.first == listId }?.second ?: "Сегодняшний день"
            val views = RemoteViews(context.packageName, R.layout.todo_widget)
            views.setTextViewText(R.id.widget_title, name)
            // свои цвета из настроек приложения; незаданные остаются системными
            style.bg?.let { views.setInt(R.id.widget_bg_fill, "setColorFilter", it) }
            style.border?.let { views.setInt(R.id.widget_bg_stroke, "setColorFilter", it) }
            views.setInt(R.id.widget_bg_fill, "setImageAlpha", style.alpha)
            views.setInt(R.id.widget_bg_stroke, "setImageAlpha", style.alpha)
            style.accent?.let {
                views.setTextColor(R.id.widget_title, it)
                views.setInt(R.id.widget_add, "setColorFilter", it)
            }
            style.muted?.let { views.setTextColor(R.id.widget_empty, it) }
            // заголовок открывает список в приложении, «+» — полную форму добавления задачи
            // так же и свободное место: надпись «Задач нет» и область под коротким списком
            val openList = HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, Uri.parse("todo://list?id=" + Uri.encode(listId)))
            views.setOnClickPendingIntent(R.id.widget_title, openList)
            views.setOnClickPendingIntent(R.id.widget_empty, openList)
            views.setOnClickPendingIntent(R.id.widget_rest, openList)
            views.setOnClickPendingIntent(R.id.widget_add,
                HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, Uri.parse("todo://new")))

            val service = Intent(context, TodoWidgetService::class.java).apply {
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                data = Uri.parse("todo://widget/$id/" + Uri.encode(listId))
            }
            @Suppress("DEPRECATION")
            views.setRemoteAdapter(R.id.widget_list, service)
            views.setEmptyView(R.id.widget_list, R.id.widget_empty)

            // нажатия по строкам принимает WidgetActionReceiver: галочка это или сама задача, он разбирает сам
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= 31) flags = flags or PendingIntent.FLAG_MUTABLE
            val template = PendingIntent.getBroadcast(context, id, Intent(context, WidgetActionReceiver::class.java), flags)
            views.setPendingIntentTemplate(R.id.widget_list, template)

            appWidgetManager.updateAppWidget(id, views)
        }
        @Suppress("DEPRECATION")
        appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetIds, R.id.widget_list)
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        val e = WidgetData.prefs(context).edit()
        for (id in appWidgetIds) e.remove("widget_list_$id").remove("widget_order_$id")
        e.apply()
        super.onDeleted(context, appWidgetIds)
    }
}

class TodoWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        Factory(applicationContext, intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, 0))

    private class Factory(val context: Context, val widgetId: Int) : RemoteViewsFactory {
        private var rows = JSONArray()
        private var style = WidgetData.Style(null, null, null, null, 255)

        override fun onCreate() {}
        // После нажатия на галочку строки остаются на своих местах: закрытая задача не прыгает в конец
        // списка, пока действует удержание порядка (WidgetData.holdOrder). Порядок из приложения
        // вернётся при первом обновлении после этого срока.
        override fun onDataSetChanged() {
            val list = WidgetData.listOf(context, widgetId)
            var data = WidgetData.tasks(context, list)
            style = WidgetData.style(context)
            val prefs = WidgetData.prefs(context)
            val key = "widget_order_$widgetId"
            if (System.currentTimeMillis() < prefs.getLong(WidgetData.HOLD_UNTIL, 0)) {
                val saved = try { JSONObject(prefs.getString(key, null) ?: "{}") } catch (e: Exception) { JSONObject() }
                val ids = saved.optJSONArray("ids")
                if (saved.optString("list") == list && ids != null) {
                    val place = HashMap<String, Int>()
                    for (i in 0 until ids.length()) place[ids.optString(i)] = i
                    val items = (0 until data.length()).mapNotNull { data.optJSONObject(it) }
                    // новые задачи (их не было на экране) идут после знакомых, в порядке приложения
                    val sorted = items.withIndex().sortedWith(compareBy({ place[it.value.optString("id")] ?: Int.MAX_VALUE }, { it.index }))
                    data = JSONArray().also { a -> sorted.forEach { a.put(it.value) } }
                }
            }
            rows = data
            val shown = JSONArray()
            for (i in 0 until rows.length()) shown.put(rows.optJSONObject(i)?.optString("id") ?: "")
            prefs.edit().putString(key, JSONObject().put("list", list).put("ids", shown).toString()).apply()
        }        override fun onDestroy() {}
        override fun getCount(): Int = rows.length()
        override fun getLoadingView(): RemoteViews? = null
        override fun getViewTypeCount(): Int = 1
        override fun getItemId(position: Int): Long = (rows.optJSONObject(position)?.optString("id") ?: "").hashCode().toLong()
        override fun hasStableIds(): Boolean = true

        override fun getViewAt(position: Int): RemoteViews {
            val t = rows.optJSONObject(position) ?: return RemoteViews(context.packageName, R.layout.todo_widget_item)
            val id = t.optString("id")
            val views = RemoteViews(context.packageName, R.layout.todo_widget_item)
            var title = t.optString("title").ifEmpty { "Без названия" }
            if (t.optBoolean("private")) title = "🔒 $title"
            views.setTextViewText(R.id.item_title, title)
            // цвета задаются каждый раз заново: строки списка переиспользуются
            val text = style.text ?: context.getColor(R.color.widget_text)
            val muted = style.muted ?: context.getColor(R.color.widget_muted)
            // подложка строки — цвет текста с малой непрозрачностью: видна и на светлом, и на тёмном фоне
            views.setInt(R.id.item_bg, "setColorFilter", (text and 0x00FFFFFF) or (0x1C shl 24))
            val due = t.optString("due")
            views.setViewVisibility(R.id.item_due, if (due.isEmpty()) View.GONE else View.VISIBLE)
            views.setTextViewText(R.id.item_due, due)
            views.setTextColor(R.id.item_due, if (t.optBoolean("overdue")) context.getColor(R.color.widget_danger) else muted)
            views.setViewVisibility(R.id.item_star, if (t.optBoolean("important")) View.VISIBLE else View.GONE)
            views.setTextColor(R.id.item_star, style.accent ?: context.getColor(R.color.widget_accent))
            views.setInt(R.id.item_check, "setColorFilter", muted)
            views.setViewVisibility(R.id.item_indent, if (t.optBoolean("sub")) View.VISIBLE else View.GONE)
            // закрытые задачи идут в конце списка: зачёркнуты и приглушены
            val done = t.optBoolean("done")
            views.setInt(R.id.item_title, "setPaintFlags", if (done) Paint.ANTI_ALIAS_FLAG or Paint.STRIKE_THRU_TEXT_FLAG else Paint.ANTI_ALIAS_FLAG)
            views.setTextColor(R.id.item_title, if (done) muted else text)
            views.setImageViewResource(R.id.item_check, if (done) R.drawable.widget_check_done else R.drawable.widget_check)
            // галочка закрывает задачу (если это разрешено и нет открытых подзадач) или возвращает закрытую; строка открывает задачу
            val can = t.optBoolean("can", true)
            views.setInt(R.id.item_check, "setImageAlpha", if (can) 255 else 90)
            views.setOnClickFillInIntent(R.id.item_check, Intent().apply {
                putExtra(WidgetData.EXTRA_ACTION, if (!can) "open" else if (done) "reopen" else "toggle")
                putExtra(WidgetData.EXTRA_TASK, id)
            })
            views.setOnClickFillInIntent(R.id.item_body, Intent().apply {
                putExtra(WidgetData.EXTRA_ACTION, "open")
                putExtra(WidgetData.EXTRA_TASK, id)
            })
            return views
        }
    }
}

/**
 * Нажатия в списке виджета. Приёмник, а не активность: запуск промежуточной активности
 * давал заметную задержку между нажатием и откликом.
 */
class WidgetActionReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val task = intent.getStringExtra(WidgetData.EXTRA_TASK) ?: ""
        if (task.isEmpty()) return
        when (val action = intent.getStringExtra(WidgetData.EXTRA_ACTION)) {
            // галочка сразу меняет вид строки, само действие выполняет фоновый обработчик
            "toggle", "reopen" -> {
                WidgetData.holdOrder(context)
                WidgetData.markDone(context, task, action == "toggle")
                WidgetData.refreshAll(context)
                HomeWidgetBackgroundIntent.getBroadcast(context, Uri.parse("todo://toggle?id=" + Uri.encode(task))).send()
            }
            "open" -> context.startActivity(Intent(context, MainActivity::class.java).apply {
                this.action = HomeWidgetLaunchIntent.HOME_WIDGET_LAUNCH_ACTION
                data = Uri.parse("todo://task?id=" + Uri.encode(task))
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            })
        }
    }
}
/** Выбор списка при размещении виджета. */
class TodoWidgetConfigActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setResult(RESULT_CANCELED)
        val widgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }
        // свой заголовок и отступы под системные панели (на Android 15 окно занимает весь экран)
        requestWindowFeature(android.view.Window.FEATURE_NO_TITLE)
        val lists = WidgetData.lists(this)
        val density = resources.displayMetrics.density
        val root = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            fitsSystemWindows = true
        }
        root.addView(android.widget.TextView(this).apply {
            text = "Список для виджета"
            textSize = 20f
            setPadding((20 * density).toInt(), (20 * density).toInt(), (20 * density).toInt(), (12 * density).toInt())
        })
        val list = ListView(this)
        list.adapter = ArrayAdapter(this, android.R.layout.simple_list_item_1, lists.map { it.second })
        list.setOnItemClickListener { _, _, position, _ ->
            WidgetData.prefs(this).edit().putString("widget_list_$widgetId", lists[position].first).commit()
            val mgr = AppWidgetManager.getInstance(this)
            TodoWidgetProvider().onUpdate(this, mgr, intArrayOf(widgetId), WidgetData.prefs(this))
            setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
            finish()
        }
        root.addView(list)
        setContentView(root)
    }
}
