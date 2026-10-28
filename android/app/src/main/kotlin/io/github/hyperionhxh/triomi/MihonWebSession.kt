package io.github.hyperionhxh.triomi

import android.app.Activity
import android.app.Dialog
import android.graphics.Color
import android.os.Build
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.ViewGroup
import android.webkit.WebResourceRequest
import android.webkit.WebResourceError
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.ProgressBar
import eu.kanade.tachiyomi.network.AndroidCookieJar
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/** Validate a homepage before handing it to a browser; never export login URLs. */
internal fun sourceWebsiteUrl(value: String): okhttp3.HttpUrl {
    require(value.none { it <= ' ' || it == '\\' }) { "website URL contains invalid characters" }
    val url = requireNotNull(value.toHttpUrlOrNull()) { "source website must use HTTP(S)" }
    require(url.username.isEmpty() && url.password.isEmpty()) { "website URL must not contain credentials" }
    val sensitive = Regex("(^|[_\\-.])(access.?token|refresh.?token|id.?token|token|auth|authorization|password|passwd|secret|credential|cookie|session|sessionid|jwt|signature|sig|api.?key|key)($|[_\\-.])", RegexOption.IGNORE_CASE)
    require(url.queryParameterNames.none { sensitive.containsMatchIn(it) }) { "website URL contains authentication parameters" }
    val fragment = url.fragment.orEmpty()
    val fragmentParameters = listOf(fragment, fragment.substringAfter('?', ""))
    require(fragmentParameters.none { parameters ->
        ("https://source.invalid/?" + parameters).toHttpUrlOrNull()
            ?.queryParameterNames?.any { sensitive.containsMatchIn(it) } == true
    }) { "website URL contains authentication parameters" }
    return url
}

/** Visible source login/verification. Completion means session saved, not challenge solved. */
class MihonWebSession(
    private val activity: Activity,
    url: String,
    userAgent: String,
    private val ruleSourceId: String? = null,
    private val onComplete: (Boolean) -> Unit,
) {
    private val origin = sourceWebsiteUrl(url)
    private val cookies = AndroidCookieJar(activity)
    private val dialog = Dialog(activity, android.R.style.Theme_Material_Light_NoActionBar)
    private val webView = WebView(activity)
    private val hosts = mutableSetOf(origin.host)
    private var saved = false
    private var finished = false

    init {
        val layout = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
        layout.setOnApplyWindowInsetsListener { view, insets ->
            if (Build.VERSION.SDK_INT >= 30) {
                val safe = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.ime())
                view.setPadding(safe.left, safe.top, safe.right, safe.bottom)
            } else {
                @Suppress("DEPRECATION")
                view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop,
                    insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
            }
            insets
        }
        val address = TextView(activity).apply {
            text = origin.host
            setTextColor(Color.DKGRAY)
            setPadding(16, 12, 16, 12)
        }
        val tools = LinearLayout(activity)
        val status = TextView(activity).apply { setPadding(16, 8, 16, 8) }
        val progress = ProgressBar(activity, null, android.R.attr.progressBarStyleHorizontal)
        fun button(label: String, action: () -> Unit) {
            tools.addView(Button(activity).apply {
                text = label
                setOnClickListener { action() }
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        }
        button("返回") { if (webView.canGoBack()) webView.goBack() else dialog.dismiss() }
        button("刷新") { webView.reload() }
        button("保存会话") {
            if (ruleSourceId == null) cookies.useBrowserSession(hosts)
            else cookies.useRuleBrowserSession(ruleSourceId, hosts)
            saved = true
            dialog.dismiss()
        }
        layout.addView(address)
        layout.addView(tools)
        layout.addView(progress, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, (3 * activity.resources.displayMetrics.density).toInt(),
        ))
        layout.addView(status)
        layout.addView(webView, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        dialog.setContentView(layout)
        dialog.setOnDismissListener {
            if (!finished) {
                finished = true
                webView.stopLoading()
                webView.destroy()
                onComplete(saved)
            }
        }
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            userAgentString = userAgent
            allowFileAccess = false
            allowContentAccess = false
        }
        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                request.url.toString().toHttpUrlOrNull()?.let {
                    it.username.isNotEmpty() || it.password.isNotEmpty() ||
                        (ruleSourceId != null && !it.isHttps)
                } ?: true

            override fun onPageStarted(view: WebView, url: String, favicon: android.graphics.Bitmap?) {
                status.visibility = android.view.View.GONE
                progress.visibility = android.view.View.VISIBLE
                url.toHttpUrlOrNull()?.let {
                    hosts.add(it.host)
                    address.text = it.host
                }
            }

            override fun onPageFinished(view: WebView, url: String) {
                progress.visibility = android.view.View.GONE
            }

            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (!request.isForMainFrame) return
                status.text = "网站加载失败（${error.errorCode}）"
                status.visibility = android.view.View.VISIBLE
                progress.visibility = android.view.View.GONE
            }
        }
    }

    fun show() {
        dialog.show()
        dialog.window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        dialog.window?.let { window ->
            if (Build.VERSION.SDK_INT >= 30) {
                val appearance = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
                    WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
                window.insetsController?.setSystemBarsAppearance(appearance, appearance)
            } else {
                @Suppress("DEPRECATION")
                window.decorView.systemUiVisibility = android.view.View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or
                    if (Build.VERSION.SDK_INT >= 26) android.view.View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR else 0
            }
        }
        cookies.prepareBrowser(origin) {
            if (!finished) webView.loadUrl(origin.toString())
        }
    }

    fun close() = dialog.dismiss()
}
