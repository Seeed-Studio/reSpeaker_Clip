package io.sensecraft.voice.android

import java.io.File
import kotlin.math.roundToInt

/** Immutable resume snapshot shared by BLE and Wi-Fi transfer flows. */
data class SessionResumeMarkers(
    val startFile: String?,
    val resumeByteOffset: Int,
    val resumeFileIndex: Int,
)

/** Number of files completed before a firmware resume marker such as `0150.opus`. */
fun resumeFileIndexFromStartFile(startFile: String?): Int {
    val value = startFile?.trim()?.lowercase().orEmpty()
    val match = Regex("""^(\d{1,6})\.opus$""").matchEntire(value) ?: return 0
    val number = match.groupValues[1].toIntOrNull() ?: return 0
    return if (number <= 1) 0 else number - 1
}

/** Device total wins when a persisted expected byte count is more than 5% stale. */
fun canonicalTransferExpectedBytes(dbExpected: Int?, transferredTotal: Int): Int? {
    if (transferredTotal <= 0) return dbExpected
    if (dbExpected == null || dbExpected <= 0) return transferredTotal
    return if (dbExpected > (transferredTotal * 1.05).roundToInt()) transferredTotal else dbExpected
}

/** True when a local merged file meets the configured verification floor. */
fun localMergedFileCompleteForDelete(
    actualSize: Long,
    expectedBytes: Int?,
    verifiedBytes: Int?,
    minCompletionRatio: Double = 0.95,
): Boolean {
    require(minCompletionRatio > 0 && minCompletionRatio <= 1) {
        "minCompletionRatio must be between 0 and 1"
    }
    if (actualSize <= 0) return false
    val reference = expectedBytes?.takeIf { it > 0 } ?: verifiedBytes?.takeIf { it > 0 } ?: return false
    return actualSize >= (reference * minCompletionRatio).roundToInt()
}

fun partNumberFromSessionOpusFilename(filename: String): Int? {
    val lower = filename.lowercase()
    val stem = when {
        lower.endsWith(".opus.part") -> lower.removeSuffix(".opus.part")
        lower.endsWith(".opus") -> lower.removeSuffix(".opus")
        else -> lower
    }
    if (stem == "part_last") return 999_999
    Regex("""^(?:part_)?(\d+)$""").matchEntire(stem)?.let {
        return it.groupValues[1].toIntOrNull()
    }
    return Regex("""^_part_\d+_(\d+)$""").matchEntire(stem)
        ?.groupValues
        ?.get(1)
        ?.toIntOrNull()
}

fun compareSessionOpusPartFilename(a: String, b: String): Int {
    val first = partNumberFromSessionOpusFilename(a)
    val second = partNumberFromSessionOpusFilename(b)
    return when {
        first != null && second != null -> first.compareTo(second)
        first != null -> -1
        second != null -> 1
        else -> a.compareTo(b)
    }
}

fun isCanonicalCompleteSessionOpusSlice(filename: String): Boolean =
    Regex("""^\d+\.opus$""").matches(filename.lowercase())

data class SessionOpusSliceInventory(
    val orderedCompleteSlices: List<File>,
    val missingIndices: List<Int>,
    val maxIndex: Int,
    val allArtifacts: List<File>,
    val duplicateIndices: List<Int>,
)

/**
 * Inventories complete numbered slices. `part_last.opus` is used only when no
 * numbered slice exists, preventing a stale pre-resume tail from being merged twice.
 */
fun inventorySessionOpusParts(nonEmptyParts: List<File>): SessionOpusSliceInventory {
    val byIndex = linkedMapOf<Int, File>()
    val duplicates = mutableListOf<Int>()
    var partLast: File? = null
    val artifacts = mutableListOf<File>()
    for (file in nonEmptyParts) {
        artifacts += file
        val name = file.name.lowercase()
        if (name == "part_last.opus") {
            partLast = file
            continue
        }
        if (!isCanonicalCompleteSessionOpusSlice(name)) continue
        val index = partNumberFromSessionOpusFilename(name) ?: continue
        if (index <= 0 || index >= 999_998) continue
        if (byIndex.containsKey(index)) duplicates += index
        byIndex[index] = file
    }
    if (byIndex.isEmpty()) {
        return SessionOpusSliceInventory(
            orderedCompleteSlices = listOfNotNull(partLast),
            missingIndices = emptyList(),
            maxIndex = 0,
            allArtifacts = artifacts,
            duplicateIndices = duplicates,
        )
    }
    val maxIndex = byIndex.keys.maxOrNull() ?: 0
    val missing = mutableListOf<Int>()
    val ordered = mutableListOf<File>()
    for (index in 1..maxIndex) {
        byIndex[index]?.let(ordered::add) ?: missing.add(index)
    }
    return SessionOpusSliceInventory(ordered, missing, maxIndex, artifacts, duplicates)
}

private fun nonEmptySessionArtifacts(directory: File): List<File> =
    directory.listFiles()
        ?.asSequence()
        ?.filter { it.isFile }
        ?.filter {
            val name = it.name.lowercase()
            name.endsWith(".opus") || name.endsWith(".opus.part")
        }
        ?.filter { runCatching { it.length() > 0 }.getOrDefault(false) }
        ?.toList()
        .orEmpty()

fun sumCompleteSessionOpusSliceBytes(sessionDirectory: File): Int =
    inventorySessionOpusParts(nonEmptySessionArtifacts(sessionDirectory))
        .orderedCompleteSlices
        .sumOf { runCatching { it.length().toInt() }.getOrDefault(0) }

fun sumSessionOpusPartBytes(sessionDirectory: File): Int =
    nonEmptySessionArtifacts(sessionDirectory)
        .sumOf { runCatching { it.length().toInt() }.getOrDefault(0) }

fun resolveResumeByteFloor(sessionDirectory: File, dbReceivedBytes: Int = 0): Int =
    maxOf(dbReceivedBytes.coerceAtLeast(0), sumCompleteSessionOpusSliceBytes(sessionDirectory))

fun resolveSessionResumeMarkers(
    sessionDirectory: File,
    startFile: String? = null,
    dbReceivedBytes: Int = 0,
): SessionResumeMarkers = SessionResumeMarkers(
    startFile = startFile,
    resumeByteOffset = resolveResumeByteFloor(sessionDirectory, dbReceivedBytes),
    resumeFileIndex = resumeFileIndexFromStartFile(startFile),
)

fun resolveSessionResumeStartFile(
    sessionDirectory: File,
    preferredStartFile: String? = null,
): String? {
    preferredStartFile?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
    val inventory = inventorySessionOpusParts(nonEmptySessionArtifacts(sessionDirectory))
    if (inventory.orderedCompleteSlices.isEmpty() || inventory.maxIndex == 0) return null
    val next = inventory.missingIndices.firstOrNull() ?: inventory.maxIndex + 1
    return "%04d.opus".format(next)
}

const val SESSION_OPUS_MERGE_BUFFER_BYTES: Int = 1024 * 1024
const val SESSION_OPUS_MERGE_PROGRESS_EVERY_BYTES: Int = 4 * 1024 * 1024

fun mergeSessionOpusPartFiles(
    parts: List<File>,
    mergedFile: File,
    shouldCancel: (() -> Boolean)? = null,
    onProgress: ((Int) -> Unit)? = null,
): File? {
    if (parts.isEmpty()) return null
    mergedFile.parentFile?.mkdirs()
    var total = 0
    var lastReported = 0
    val buffer = ByteArray(SESSION_OPUS_MERGE_BUFFER_BYTES)
    mergedFile.outputStream().buffered().use { output ->
        for (part in parts) {
            if (shouldCancel?.invoke() == true) {
                mergedFile.delete()
                return null
            }
            part.inputStream().buffered().use { input ->
                while (true) {
                    if (shouldCancel?.invoke() == true) {
                        mergedFile.delete()
                        return null
                    }
                    val count = input.read(buffer)
                    if (count <= 0) break
                    output.write(buffer, 0, count)
                    total += count
                    if (onProgress != null && total - lastReported >= SESSION_OPUS_MERGE_PROGRESS_EVERY_BYTES) {
                        lastReported = total
                        onProgress(total)
                    }
                }
            }
        }
    }
    if (total <= 0) {
        mergedFile.delete()
        return null
    }
    if (onProgress != null && total != lastReported) onProgress(total)
    return mergedFile
}

fun mergeSessionOpusPartsInDirectory(
    sessionDirectory: File,
    mergedFile: File,
    shouldCancel: (() -> Boolean)? = null,
    onProgress: ((Int) -> Unit)? = null,
): File? {
    val inventory = inventorySessionOpusParts(nonEmptySessionArtifacts(sessionDirectory))
    return mergeSessionOpusPartFiles(
        parts = inventory.orderedCompleteSlices,
        mergedFile = mergedFile,
        shouldCancel = shouldCancel,
        onProgress = onProgress,
    )
}
