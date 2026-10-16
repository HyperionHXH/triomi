package io.github.hyperionhxh.triomi

import android.annotation.SuppressLint
import android.app.Activity
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.webkit.*
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Uses the site's ordinary player runtime, like Kazumi; no TLS/auth bypass. */
class WebVideoResolver(private val activity: Activity) {
    private var view: WebView? = null
    private var result: MethodChannel.Result? = null
    private val handler = Handler(Looper.getMainLooper())
    private var userAgent = ""
    private var requestHeaders: Map<String, String> = emptyMap()
    private var unavailableVideoUrls: Set<String> = emptySet()
    private var requestId: String? = null

    @SuppressLint("SetJavaScriptEnabled")
    fun resolve(call: MethodCall, reply: MethodChannel.Result) {
        cancel()
        val url = call.argument<String>("url") ?: ""
        val target = Uri.parse(url)
        if (target.scheme !in listOf("https", "http") || target.host.isNullOrBlank() || target.userInfo != null) {
            reply.error("invalid_url", "播放页必须是 HTTP(S) 地址", null)
            return
        }
        result = reply
        requestId = call.argument<String>("requestId")
        requestHeaders = call.argument<Map<String, String>>("headers") ?: emptyMap()
        unavailableVideoUrls = (call.argument<List<String>>("unavailableVideoUrls") ?: emptyList()).toSet()
        val web = WebView(activity)
        view = web
        web.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            mediaPlaybackRequiresUserGesture = false
            userAgentString = requestHeaders["User-Agent"] ?: userAgentString
        }
        userAgent = web.settings.userAgentString
        web.addJavascriptInterface(object {
            @JavascriptInterface fun found(media: String) {
                handler.post { if (view === web) complete(media, emptyMap()) }
            }
        }, "TriomiMedia")
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            WebViewCompat.addDocumentStartJavaScript(web, SCRIPT, setOf("*"))
        }
        web.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(v: WebView, r: WebResourceRequest): Boolean {
                return r.url.scheme !in listOf("https", "http")
            }
            override fun shouldInterceptRequest(v: WebView, r: WebResourceRequest): WebResourceResponse? {
                val path = r.url.path ?: ""
                if (Regex("\\.(m3u8|mp4|m4v)(?:$)", RegexOption.IGNORE_CASE).containsMatchIn(path)) {
                    handler.post { if (view === web) complete(r.url.toString(), r.requestHeaders) }
                }
                return null
            }
            override fun onPageFinished(v: WebView, url: String) {
                v.evaluateJavascript(SCRIPT, null)
            }
            // Default certificate handling remains in force.
        }
        web.webChromeClient = WebChromeClient()
        handler.postDelayed({ fail("resolve_timeout", "播放页未返回可播放地址，请重试或换线路") }, 35000)
        web.loadUrl(url, requestHeaders)
    }

    private fun complete(url: String, observed: Map<String, String>) {
        val pending = result ?: return
        val uri = Uri.parse(url)
        if (uri.scheme !in listOf("https", "http") || uri.host.isNullOrBlank() || uri.userInfo != null) return
        if (listOf("googleads", "googlesyndication", "adposter").any { url.contains(it) }) return
        // The rule identifies known failure cards. Keep the resolver independent
        // of sites and do not reject arbitrary short videos or entire CDNs.
        if (url in unavailableVideoUrls) {
            fail("source_unavailable", "此线路返回了站点的加载失败占位，请从剧集目录选择另一线路")
            return
        }
        result = null
        val headers = mutableMapOf("User-Agent" to userAgent)
        // Preserve the actual media request's origin policy, including no-referrer.
        for ((key, value) in observed) {
            if (key.lowercase() in listOf("referer", "origin", "user-agent")) headers[key] = value
        }
        CookieManager.getInstance().getCookie(url)?.let { headers["Cookie"] = it }
        pending.success(mapOf("url" to url, "headers" to headers))
        cleanup()
    }

    fun cancel() = fail("resolve_cancelled", "播放解析已取消")
    fun cancel(request: String?) {
        if (request == null || request == requestId) cancel()
    }
    private fun fail(code: String, message: String) {
        val pending = result ?: return
        result = null
        pending.error(code, message, null)
        cleanup()
    }
    private fun cleanup() {
        handler.removeCallbacksAndMessages(null)
        view?.apply { stopLoading(); removeJavascriptInterface("TriomiMedia"); loadUrl("about:blank"); destroy() }
        view = null
        requestId = null
    }

    companion object {
        private val SCRIPT = """
            (() => {
              if (window.__triomiMedia) return; window.__triomiMedia = true;
              const report = u => { try { if (u && !u.startsWith('blob:')) TriomiMedia.found(new URL(u, location.href).href); } catch(e) {} };
              const text = Response.prototype.text;
              Response.prototype.text = function() { const url=this.url; return text.call(this).then(t => { if(t.trim().startsWith('#EXTM3U')) report(url); return t; }); };
              const open=XMLHttpRequest.prototype.open;
              XMLHttpRequest.prototype.open=function(m,u) { this.addEventListener('load',()=>{ try { if(this.responseText.trim().startsWith('#EXTM3U')) report(this.responseURL || u); } catch(e) {} }); return open.apply(this,arguments); };
              const scan = () => document.querySelectorAll('video,video source').forEach(v => report(v.currentSrc || v.src));
              new MutationObserver(scan).observe(document,{childList:true,subtree:true,attributes:true,attributeFilter:['src']});
              setInterval(scan,500); scan();
            })();
        """.trimIndent()
    }
}
