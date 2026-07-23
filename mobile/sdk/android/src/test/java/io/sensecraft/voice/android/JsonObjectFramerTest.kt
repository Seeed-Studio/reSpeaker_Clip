package io.sensecraft.voice.android

import org.junit.Assert.assertEquals
import org.junit.Test

class JsonObjectFramerTest {
    @Test
    fun parseAcrossChunks() {
        val framer = JsonObjectFramer()
        assertEquals(emptyList<String>(), framer.feed("{\"ok\":"))
        assertEquals(listOf("{\"ok\":true,\"a\":1}"), framer.feed("true,\"a\":1}"))
    }
}

