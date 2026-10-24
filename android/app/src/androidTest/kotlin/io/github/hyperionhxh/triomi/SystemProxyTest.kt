package io.github.hyperionhxh.triomi

import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SystemProxyTest {
    private fun selector(choose: (URI) -> List<Proxy>) = object : ProxySelector() {
        override fun select(uri: URI): List<Proxy> = choose(uri)
        override fun connectFailed(uri: URI, address: SocketAddress, error: IOException) = Unit
    }

    @Test fun routesEachUrlThroughTheCurrentSelectorAndPreservesExclusions() {
        val observed = mutableListOf<URI>()
        val route = selector { uri ->
            observed.add(uri)
            if (uri.host == "localhost") listOf(Proxy.NO_PROXY) else listOf(
                Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved("proxy.example", 8080)),
            )
        }
        assertEquals(mapOf("direct" to false, "proxy" to "proxy.example:8080", "bypass" to ""),
            resolveSystemProxy("https://next.bgm.tv/p1/episodes/1227087/comments", route))
        assertEquals(mapOf("direct" to true), resolveSystemProxy("http://localhost/media", route))
        assertEquals(listOf("next.bgm.tv", "localhost"), observed.map { it.host })
    }

    @Test fun keepsIpv6ProxyAddressesAndDirectSelection() {
        assertEquals("[::1]:7890", resolveSystemProxy("https://example.com/", selector {
            listOf(Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved("::1", 7890)))
        })["proxy"])
        assertEquals(mapOf("direct" to true), resolveSystemProxy("https://example.com/", null))
        assertEquals(mapOf("direct" to true), resolveSystemProxy("https://example.com/", selector {
            listOf(Proxy.NO_PROXY, Proxy(Proxy.Type.HTTP,
                InetSocketAddress.createUnresolved("proxy.example", 8080)))
        }))
    }

    @Test fun rejectsUnsupportedRoutesAndCredentialBearingTargets() {
        assertThrows(IllegalArgumentException::class.java) {
            resolveSystemProxy("https://example.com/", selector {
                listOf(Proxy(Proxy.Type.SOCKS, InetSocketAddress.createUnresolved("proxy.example", 1080)))
            })
        }
        assertThrows(IllegalArgumentException::class.java) {
            resolveSystemProxy("https://user:secret@example.com/", null)
        }
        assertThrows(IllegalArgumentException::class.java) {
            resolveSystemProxy("file:///data/local/tmp/content", null)
        }
    }
}
