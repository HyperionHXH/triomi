package io.github.hyperionhxh.triomi

import android.os.Bundle
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.preference.PreferenceFragmentCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import android.content.res.Configuration
import eu.kanade.tachiyomi.source.preferenceKey

/** Render the real extension's own PreferenceScreen and persist its exact ABI keys. */
class MihonSettingsActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        setTheme(androidx.appcompat.R.style.Theme_AppCompat_DayNight)
        super.onCreate(savedInstanceState)
        WindowInsetsControllerCompat(window, window.decorView).isAppearanceLightStatusBars =
            resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK != Configuration.UI_MODE_NIGHT_YES
        supportActionBar?.title = "来源设置"
        supportActionBar?.setDisplayHomeAsUpEnabled(true)
        ViewCompat.setOnApplyWindowInsetsListener(findViewById(android.R.id.content)) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }
        if (savedInstanceState == null) {
            supportFragmentManager.beginTransaction().replace(android.R.id.content,
                SettingsFragment().apply { arguments = intent.extras }).commit()
        }
    }

    override fun onSupportNavigateUp(): Boolean { finish(); return true }

    class SettingsFragment : PreferenceFragmentCompat() {
        override fun onCreatePreferences(savedInstanceState: Bundle?, rootKey: String?) {
            try {
                val host = MihonHost(requireContext())
                val source = host.settingsSource(requireArguments().getString("packageName")!!,
                    requireArguments().getString("sourceId")!!)
                preferenceManager.sharedPreferencesName = source.preferenceKey()
                preferenceScreen = preferenceManager.createPreferenceScreen(requireContext())
                source.setupPreferenceScreen(preferenceScreen)
                (requireActivity() as AppCompatActivity).supportActionBar?.title = "${source.name} · 来源设置"
            } catch (error: Throwable) {
                Toast.makeText(requireContext(), "无法打开来源设置：${error.javaClass.simpleName}", Toast.LENGTH_LONG).show()
                requireActivity().finish()
            }
        }
    }
}
