package io.github.hyperionhxh.triomi

import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.URI

/** Ask Android's current selector so Wi-Fi/PAC exclusions retain their meaning. */
internal fun resolveSystemProxy(
    value: String,
    selector: ProxySelector? = ProxySelector.getDefault(),
): Map<String, Any> {
    val uri = URI(value)
    require(uri.scheme == "http" || uri.scheme == "https") { "unsupported URL" }
    require(!uri.host.isNullOrEmpty() && uri.rawUserInfo == null) { "invalid URL" }
    val selected = selector?.select(uri)?.firstOrNull() ?: Proxy.NO_PROXY
    if (selected.type() == Proxy.Type.DIRECT) return mapOf("direct" to true)
    require(selected.type() == Proxy.Type.HTTP) { "unsupported system proxy type" }
    val address = selected.address() as? InetSocketAddress
        ?: throw IllegalArgumentException("invalid proxy address")
    require(address.port in 1..65535) { "invalid proxy port" }
    val host = address.hostString.let { if (it.contains(':')) "[$it]" else it }
    return mapOf("direct" to false, "proxy" to "$host:${address.port}", "bypass" to "")
}
