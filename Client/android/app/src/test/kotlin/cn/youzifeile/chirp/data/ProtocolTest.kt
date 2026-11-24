package cn.youzifeile.chirp.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ProtocolTest {
    @Test
    fun completesHttpsForDomainsWithOptionalPortsAndTrailingSlashes() {
        for (slash in listOf("", "/")) {
            assertEquals("https://chirp.example.com/", parseServerAddress("chirp.example.com$slash", false).toString())
            assertEquals("https://chirp.example.com:8443/", parseServerAddress("chirp.example.com:8443$slash", false).toString())
        }
        assertEquals("https://chirp.example.com/", parseServerAddress(" CHIRP.example.com:443/ ", false).toString())
    }

    @Test
    fun acceptsExactHttpsOriginsAndDebugLoopback() {
        assertEquals("https://voice.example:8443/", parseServerAddress(" https://voice.example:8443 ", false).toString())
        assertEquals("https://voice.example/chirp/", parseServerAddress("https://voice.example/chirp", false).toString())
        assertEquals("http://localhost:18175/", parseServerAddress("http://localhost:18175", true).toString())
    }

    @Test
    fun rejectsInsecureOrAmbiguousOrigins() {
        val values = listOf(
            "http://localhost:18175", "http://voice.example", "https://livekit.cloud",
            "https://edge.livekit.run.", "https://user@voice.example", "https:///voice.example",
            "https://voice.example/../", "https://voice.example/?q=1",
            "https://voice.example/#", "https://voice.example:0",
            "voice.example:invalid/", "voice.example:65536/", "https:/voice.example",
            "ftp://voice.example", "//voice.example", "user@voice.example",
        )
        for (value in values) {
            assertThrows(value, ChirpException::class.java) { parseServerAddress(value, false) }
        }
        assertThrows(ChirpException::class.java) { parseServerAddress("http://10.0.2.2:18175", true) }
    }

    @Test
    fun preservesWireRevisionsAboveJavascriptIntegerRange() {
        val raw = """{"revision":18446744073709551615}"""
        assertEquals(ULong.MAX_VALUE, parseObject(raw.encodeToByteArray()).unsigned("revision"))
        assertThrows(ChirpException::class.java) {
            parseObject("""{"revision":"18446744073709551615"}""".encodeToByteArray()).unsigned("revision")
        }
    }
}
