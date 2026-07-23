package io.sensecraft.voice.android

class JsonObjectFramer {
    private var buffer = ""

    fun feed(chunk: String): List<String> {
        if (chunk.isEmpty()) return emptyList()
        buffer += chunk
        val out = mutableListOf<String>()

        while (true) {
            val start = buffer.indexOf('{')
            if (start < 0) {
                if (buffer.length > 4096) buffer = buffer.takeLast(1024)
                return out
            }
            if (start > 0) buffer = buffer.substring(start)
            val end = findJsonObjectEnd(buffer) ?: return out
            val obj = buffer.substring(0, end).trim()
            buffer = buffer.substring(end)
            if (obj.isNotEmpty()) out += obj
        }
    }

    private fun findJsonObjectEnd(s: String): Int? {
        var depth = 0
        var inString = false
        var escaped = false

        for (i in s.indices) {
            val ch = s[i]
            if (inString) {
                if (escaped) {
                    escaped = false
                } else when (ch) {
                    '\\' -> escaped = true
                    '"' -> inString = false
                }
                continue
            }
            when (ch) {
                '"' -> inString = true
                '{' -> depth++
                '}' -> {
                    depth--
                    if (depth == 0) return i + 1
                }
            }
        }
        return null
    }
}

