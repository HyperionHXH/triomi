package io.github.hyperionhxh.triomi

import android.annotation.SuppressLint
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.webkit.*
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Uses the site's ordinary player runtime, like Kazumi; no TLS/auth bypass. */
class WebVideoResolver(private val context: Context) {
    private var view: WebView? = null
    private var result: MethodChannel.Result? = null
    private val handler = Handler(Looper.getMainLooper())
    private var timeout: Runnable? = null
    private var userAgent = ""
    private var unavailableVideoUrls: Set<String> = emptySet()
    private var requestId: String? = null
    private var requestGeneration = 0L

    @SuppressLint("SetJavaScriptEnabled")
    fun resolve(call: MethodCall, reply: MethodChannel.Result) {
        val generation = ++requestGeneration
        cancel()
        if (generation != requestGeneration) {
            reply.error("resolve_cancelled", "播放解析已取消", null)
            return
        }
        val url = call.argument<String>("url") ?: ""
        val target = Uri.parse(url)
        if (target.scheme !in listOf("https", "http") || target.host.isNullOrBlank() || target.userInfo != null) {
            reply.error("invalid_url", "播放页必须是 HTTP(S) 地址", null)
            return
        }
        result = reply
        requestId = call.argument<String>("requestId")
        val requestHeaders = call.argument<Map<String, String>>("headers") ?: emptyMap()
        unavailableVideoUrls = (call.argument<List<String>>("unavailableVideoUrls") ?: emptyList()).toSet()
        val script = detectionScript(call.argument<Boolean>("useLegacyParser") == true)
        val observedRequests = object : LinkedHashMap<String, Map<String, String>>() {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Map<String, String>>): Boolean = size > 128
        }
        val web = WebView(context)
        view = web
        web.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            mediaPlaybackRequiresUserGesture = false
            userAgentString = requestHeaders.entries.firstOrNull { it.key.equals("User-Agent", true) }?.value ?: userAgentString
        }
        userAgent = web.settings.userAgentString
        web.addJavascriptInterface(object {
            @JavascriptInterface fun found(media: String, mimeType: String, omitCookies: Boolean) {
                handler.post {
                    if (view !== web) return@post
                    val observed = synchronized(observedRequests) { observedRequests[media] }
                    if (observed != null) {
                        complete(media, observed, mimeType, omitCookies)
                    } else {
                        // A source mutation can precede WebView's actual request.
                        handler.postDelayed({
                            if (view === web) {
                                val lateHeaders = synchronized(observedRequests) { observedRequests[media] }
                                complete(media, lateHeaders ?: emptyMap(), mimeType, omitCookies)
                            }
                        }, 100)
                    }
                }
            }
        }, "TriomiMedia")
        val documentStartSupported = WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)
        if (documentStartSupported) {
            WebViewCompat.addDocumentStartJavaScript(web, script, setOf("*"))
        }
        web.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(v: WebView, r: WebResourceRequest): Boolean {
                return r.url.scheme !in listOf("https", "http")
            }
            override fun shouldInterceptRequest(v: WebView, r: WebResourceRequest): WebResourceResponse? {
                val mediaUrl = r.url.toString()
                val observed = r.requestHeaders.toMap()
                synchronized(observedRequests) { observedRequests[mediaUrl] = observed }
                if (MEDIA_PATH.containsMatchIn(r.url.path ?: "")) {
                    handler.post { if (view === web) complete(mediaUrl, observed) }
                }
                return null
            }
            override fun onPageStarted(v: WebView, url: String, favicon: android.graphics.Bitmap?) {
                if (view === web && !documentStartSupported) v.evaluateJavascript(script, null)
            }
            override fun onPageFinished(v: WebView, url: String) {
                if (view === web) v.evaluateJavascript(script, null)
            }
            // Default certificate handling remains in force.
        }
        web.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(v: WebView, newProgress: Int) {
                // Older WebViews have no document-start API. Do not wait for
                // every image/ad to finish before installing the fallback.
                if (view === web && !documentStartSupported && newProgress in 1..99) v.evaluateJavascript(script, null)
            }
        }
        timeout = Runnable {
            if (view === web) fail("resolve_timeout", "播放页未返回可播放地址，请重试或换线路")
        }.also { handler.postDelayed(it, 35000) }
        web.loadUrl(url, requestHeaders)
    }

    private fun complete(url: String, observed: Map<String, String>, mimeType: String = "", omitCookies: Boolean = false) {
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
        val headers = mutableMapOf("User-Agent" to userAgent)
        // Preserve the actual media request's origin policy, including no-referrer.
        for ((key, value) in observed) {
            when (key.lowercase()) {
                "referer" -> headers["Referer"] = value
                "origin" -> headers["Origin"] = value
                "user-agent" -> headers["User-Agent"] = value
                "cookie" -> if (!omitCookies) headers["Cookie"] = value
            }
        }
        if (!omitCookies && !headers.containsKey("Cookie")) {
            CookieManager.getInstance().getCookie(url)?.let { headers["Cookie"] = it }
        }
        val response = mutableMapOf<String, Any>("url" to url, "headers" to headers)
        if (mimeType == HLS_MIME_TYPE) response["mimeType"] = HLS_MIME_TYPE
        if (omitCookies) response["omitCookies"] = true
        cleanup()
        pending.success(response)
    }

    fun cancel() = fail("resolve_cancelled", "播放解析已取消")
    fun cancel(request: String?) {
        if (request == null || request == requestId) cancel()
    }
    private fun fail(code: String, message: String) {
        val pending = result ?: return
        cleanup()
        pending.error(code, message, null)
    }
    private fun cleanup() {
        result = null
        val oldView = view
        view = null
        requestId = null
        timeout = null
        handler.removeCallbacksAndMessages(null)
        oldView?.apply { stopLoading(); removeJavascriptInterface("TriomiMedia"); loadUrl("about:blank"); destroy() }
    }

    companion object {
        private const val HLS_MIME_TYPE = "application/vnd.apple.mpegurl"
        private val MEDIA_PATH = Regex("\\.(m3u8|mp4|m4v)$", RegexOption.IGNORE_CASE)

        internal fun detectionScript(useLegacyParser: Boolean): String = SCRIPT.replace("__TRIOMI_LEGACY__", useLegacyParser.toString())

        private val SCRIPT = """
            (() => {
              if (window.__triomiMedia) return; window.__triomiMedia = true;
              const legacy = __TRIOMI_LEGACY__;
              const hls = 'application/vnd.apple.mpegurl';
              const isHls = type => /^(application\/(vnd\.apple\.mpegurl|x-mpegurl|mpegurl)|audio\/(mpegurl|x-mpegurl))$/i.test((type || '').split(';')[0].trim());
              const sent = new Map();
              const absolute = u => { try { const v = new URL(u, location.href); return /^https?:$/.test(v.protocol) && !v.username && !v.password ? v.href : ''; } catch(e) { return ''; } };
              const report = (u, mime = '', omitCookies = false) => {
                const url = u && absolute(u);
                if (!url || sent.has(url) && (!mime || sent.get(url))) return;
                sent.set(url, mime);
                try { TriomiMedia.found(url, mime, omitCookies); } catch(e) {}
              };
              const responseRequests = new WeakMap();
              const clone = Response.prototype.clone;
              Response.prototype.clone = function() {
                const response = clone.call(this), metadata = responseRequests.get(this);
                if (metadata) responseRequests.set(response, metadata);
                return response;
              };
              const text = Response.prototype.text;
              Response.prototype.text = function() {
                const url = this.url, metadata = responseRequests.get(this) || {};
                return text.call(this).then(t => { if(t.trim().startsWith('#EXTM3U')) report(url, hls, metadata.omit); return t; });
              };
              const fetch = window.fetch;
              window.fetch = function(input, init) {
                const request = input instanceof Request ? input.url : String(input);
                const credentials = init && init.credentials || (input instanceof Request ? input.credentials : 'same-origin');
                let omit = credentials === 'omit';
                try { omit = omit || credentials === 'same-origin' && (new URL(request, location.href).origin !== location.origin); } catch(e) {}
                return fetch.apply(this, arguments).then(response => {
                  const url = response.url || request;
                  try { omit = omit || credentials === 'same-origin' && (new URL(url, location.href).origin !== location.origin); } catch(e) {}
                  responseRequests.set(response, {omit});
                  if (isHls(response.headers.get('Content-Type'))) {
                    report(url, hls, omit);
                  } else if (response.body && response.type !== 'opaque') {
                    // Inspect only a bounded prefix, without consuming the player's body.
                    try {
                      const reader = response.clone().body.getReader();
                      const timer = setTimeout(() => { reader.cancel().catch(() => {}); }, 5000);
                      const decoder = new TextDecoder();
                      let prefix = '';
                      let bytes = 0;
                      const read = () => reader.read().then(part => {
                        if (part.value) {
                          bytes += part.value.byteLength;
                          prefix += decoder.decode(part.value.subarray(0, Math.max(0, 512 - prefix.length)), {stream: true});
                        }
                        const trimmed = prefix.trimStart();
                        if (trimmed.startsWith('#EXTM3U')) {
                          clearTimeout(timer);
                          reader.cancel().catch(() => {}); report(url, hls, omit);
                        } else if (part.done || bytes >= 512 || trimmed.length >= 7) {
                          clearTimeout(timer);
                          reader.cancel().catch(() => {});
                        } else return read();
                      }).catch(() => { clearTimeout(timer); });
                      read();
                    } catch(e) {}
                  }
                  return response;
                });
              };
              const open = XMLHttpRequest.prototype.open;
              XMLHttpRequest.prototype.open = function(m, u) {
                const request = absolute(u);
                this.addEventListener('load', () => {
                  const url = this.responseURL || request;
                  try {
                    const omit = !this.withCredentials && (new URL(request).origin !== location.origin || new URL(url, location.href).origin !== location.origin);
                    if (isHls(this.getResponseHeader('Content-Type')) ||
                        (!this.responseType || this.responseType === 'text') && this.responseText.trim().startsWith('#EXTM3U')) report(url, hls, omit);
                    else if (this.responseType === 'arraybuffer' && this.response instanceof ArrayBuffer &&
                        new TextDecoder().decode(new Uint8Array(this.response, 0, Math.min(512, this.response.byteLength))).trim().startsWith('#EXTM3U')) report(url, hls, omit);
                    else if (this.responseType === 'blob' && this.response instanceof Blob) {
                      this.response.slice(0,512).text().then(t => { if(t.trim().startsWith('#EXTM3U')) report(url, hls, omit); }).catch(() => {});
                    }
                  } catch(e) {}
                }, {once: true});
                return open.apply(this, arguments);
              };
              const scan = () => {
                document.querySelectorAll('video,video source').forEach(v => {
                  report(v.currentSrc, isHls(v.type) ? hls : '');
                  report(v.src, isHls(v.type) ? hls : '');
                });
                if (!legacy) return;
                document.querySelectorAll('iframe[src]').forEach(frame => {
                  try {
                    const url = new URL(frame.src, location.href);
                    for (const value of url.searchParams.values()) {
                      const media = absolute(value);
                      if (media && /\.(m3u8|mp4|m4v)$/i.test(new URL(media).pathname)) report(media, /\.m3u8$/i.test(new URL(media).pathname) ? hls : '');
                    }
                  } catch(e) {}
                });
              };
              new MutationObserver(scan).observe(document,{childList:true,subtree:true,attributes:true,attributeFilter:['src','type']});
              setInterval(scan,500); scan();
            })();
        """.trimIndent()
    }
}
