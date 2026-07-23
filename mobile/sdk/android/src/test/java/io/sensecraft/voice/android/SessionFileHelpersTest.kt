package io.sensecraft.voice.android

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionFileHelpersTest {
    @Test
    fun resumeMarkersUseFirstGapAndCanonicalByteFloor() {
        val directory = Files.createTempDirectory("voice-resume").toFile()
        try {
            File(directory, "0001.opus").writeBytes(ByteArray(3))
            File(directory, "0003.opus").writeBytes(ByteArray(5))
            File(directory, "0002.opus.part").writeBytes(ByteArray(100))

            assertEquals("0002.opus", resolveSessionResumeStartFile(directory))
            assertEquals(2, resumeFileIndexFromStartFile("0003.opus"))
            assertEquals(8, resolveResumeByteFloor(directory))
            assertEquals(12, resolveResumeByteFloor(directory, dbReceivedBytes = 12))
            val markers = resolveSessionResumeMarkers(directory, "0003.opus", 2)
            assertEquals(8, markers.resumeByteOffset)
            assertEquals(2, markers.resumeFileIndex)
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun partLastIsIgnoredAfterCanonicalSlicesExist() {
        val directory = Files.createTempDirectory("voice-inventory").toFile()
        try {
            val staleTail = File(directory, "part_last.opus").apply { writeText("stale") }
            val first = File(directory, "0001.opus").apply { writeText("one") }
            val inventory = inventorySessionOpusParts(listOf(staleTail, first))
            assertEquals(listOf(first), inventory.orderedCompleteSlices)
            assertEquals(1, inventory.maxIndex)
            assertTrue(inventory.missingIndices.isEmpty())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun mergeUsesCanonicalNumericOrder() {
        val directory = Files.createTempDirectory("voice-merge").toFile()
        try {
            File(directory, "0002.opus").writeBytes(byteArrayOf(3, 4))
            File(directory, "0001.opus").writeBytes(byteArrayOf(1, 2))
            File(directory, "0001.opus.part").writeBytes(byteArrayOf(99))
            val merged = File(directory.parentFile, "${directory.name}.opus")
            try {
                assertEquals(merged, mergeSessionOpusPartsInDirectory(directory, merged))
                assertArrayEquals(byteArrayOf(1, 2, 3, 4), merged.readBytes())
            } finally {
                merged.delete()
            }
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun expectedBytesAndDeleteVerificationMatchFlutterRules() {
        assertEquals(100, canonicalTransferExpectedBytes(200, 100))
        assertEquals(98, canonicalTransferExpectedBytes(98, 100))
        assertEquals(100, canonicalTransferExpectedBytes(null, 100))
        assertTrue(localMergedFileCompleteForDelete(95, 100, null))
        assertFalse(localMergedFileCompleteForDelete(94, 100, null))
        assertFalse(localMergedFileCompleteForDelete(100, null, null))
    }

    @Test
    fun emptyDirectoryHasNoResumeOrMerge() {
        val directory = Files.createTempDirectory("voice-empty").toFile()
        try {
            assertNull(resolveSessionResumeStartFile(directory))
            assertNull(mergeSessionOpusPartsInDirectory(directory, File(directory, "merged.opus")))
        } finally {
            directory.deleteRecursively()
        }
    }
}
