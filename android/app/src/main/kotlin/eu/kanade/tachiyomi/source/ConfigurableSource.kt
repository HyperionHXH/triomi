package eu.kanade.tachiyomi.source

import android.content.Context
import android.content.SharedPreferences

interface ConfigurableSource : Source {
    fun getSourcePreferences(): SharedPreferences =
        MihonPreferences.application().getSharedPreferences(preferenceKey(), Context.MODE_PRIVATE)

    fun setupPreferenceScreen(screen: PreferenceScreen)
}

fun ConfigurableSource.preferenceKey(): String = "source_${id}"

fun ConfigurableSource.sourcePreferences(): SharedPreferences = getSourcePreferences()

fun sourcePreferences(key: String): SharedPreferences =
    MihonPreferences.application().getSharedPreferences(key, Context.MODE_PRIVATE)

internal object MihonPreferences {
    @Volatile private var context: Context? = null
    fun install(context: Context) { this.context = context.applicationContext }
    fun application(): Context = context ?: error("Mihon preferences are not initialized")
}
