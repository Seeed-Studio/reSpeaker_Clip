package io.sensecraft.voice.android

class BleTransferFrameState {
    var useFraming: Boolean = false
    var currentFilename: String? = null
    var currentFileDeclaredSize: Int = 0
    var bytesThisFile: Int = 0
    var fileCrc: Long = 0
    var nextSeq: Int = 0
    var fileCompleteCount: Int = 0
}

sealed class BleTransferFrameResult {
    data class Invalid(val reason: String) : BleTransferFrameResult()
    data class Raw(val bytes: ByteArray) : BleTransferFrameResult()
    data class UnexpectedRaw(val length: Int) : BleTransferFrameResult()
    data class FileStart(val filename: String, val fileSize: Int) : BleTransferFrameResult()
    data class Data(
        val seq: Int,
        val payload: ByteArray,
        val duplicateSeq: Boolean,
        val seqJump: Boolean,
        val orphanBeforeFileStart: Boolean,
    ) : BleTransferFrameResult()
    data class FileEndOk(
        val filename: String,
        val localCrc32: Long,
        val deviceCrc32: Long,
        val fileCompleteCount: Int,
        val declaredFileSize: Int,
        val bytesThisFile: Int,
        val usedFraming: Boolean,
    ) : BleTransferFrameResult()
    data class FileEndStale(val filename: String, val deviceCrc32: Long) : BleTransferFrameResult()
    data class FileEndCrcMismatch(
        val filename: String,
        val localCrc32: Long,
        val deviceCrc32: Long,
        val resyncStartFile: String,
    ) : BleTransferFrameResult()
    data class TransferDone(val sessionId: String, val fileCount: Int) : BleTransferFrameResult()
}

object BleTransferFrameHandler {
    fun sanitizeFilename(name: String): String {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return "part.opus"
        val safe = buildString(trimmed.length) {
            for (ch in trimmed) {
                append(
                    when (ch.code) {
                        in 48..57, in 65..90, in 97..122, 45, 46, 95 -> ch
                        47, 92 -> '_'
                        else -> '_'
                    },
                )
            }
        }
        return if (safe.isEmpty()) "part.opus" else safe
    }

    fun orphanFilenameBeforeFileStart(
        effectiveStartFile: String?,
        fileCompleteCount: Int,
    ): String {
        val trimmed = effectiveStartFile?.trim()
        if (!trimmed.isNullOrEmpty()) return trimmed
        return "%04d.opus".format(fileCompleteCount + 1)
    }

    fun partNumberFromFilename(name: String): Int? {
        val trimmed = name.trim().lowercase()
        if (!trimmed.endsWith(".opus") || trimmed.length != 9) return null
        val prefix = trimmed.take(4)
        if (!prefix.all { it in '0'..'9' }) return null
        return prefix.toIntOrNull()
    }

    fun handle(
        bytes: ByteArray,
        state: BleTransferFrameState,
        effectiveStartFile: String? = null,
    ): BleTransferFrameResult {
        when (val parsed = parseClipFileDataNotify(bytes)) {
            is ClipFileDataParsed.Invalid -> return BleTransferFrameResult.Invalid(parsed.reason)
            is ClipFileDataParsed.Raw -> {
                if (state.useFraming) return BleTransferFrameResult.UnexpectedRaw(parsed.bytes.size)
                return BleTransferFrameResult.Raw(parsed.bytes)
            }
            is ClipFileDataParsed.FileStart -> {
                state.useFraming = true
                state.currentFilename = parsed.filename
                state.currentFileDeclaredSize = parsed.fileSize
                state.bytesThisFile = 0
                state.fileCrc = 0
                state.nextSeq = 0
                return BleTransferFrameResult.FileStart(parsed.filename, parsed.fileSize)
            }
            is ClipFileDataParsed.Data -> {
                state.useFraming = true
                var orphanBeforeFileStart = false
                if (state.currentFilename == null) {
                    orphanBeforeFileStart = true
                    val guess = orphanFilenameBeforeFileStart(
                        effectiveStartFile = effectiveStartFile,
                        fileCompleteCount = state.fileCompleteCount,
                    )
                    state.currentFilename = sanitizeFilename(guess)
                    state.nextSeq = parsed.seq
                    state.fileCrc = 0
                }

                var duplicateSeq = false
                var seqJump = false
                if (parsed.seq != state.nextSeq) {
                    if (parsed.seq < state.nextSeq) {
                        duplicateSeq = true
                        return BleTransferFrameResult.Data(
                            seq = parsed.seq,
                            payload = parsed.payload,
                            duplicateSeq = true,
                            seqJump = false,
                            orphanBeforeFileStart = orphanBeforeFileStart,
                        )
                    }
                    seqJump = true
                    state.nextSeq = parsed.seq
                }
                state.nextSeq = parsed.seq + 1

                if (state.currentFileDeclaredSize > 0) {
                    state.bytesThisFile += parsed.payload.size
                }
                state.fileCrc = crc32Ieee(parsed.payload, state.fileCrc)

                return BleTransferFrameResult.Data(
                    seq = parsed.seq,
                    payload = parsed.payload,
                    duplicateSeq = duplicateSeq,
                    seqJump = seqJump,
                    orphanBeforeFileStart = orphanBeforeFileStart,
                )
            }
            is ClipFileDataParsed.FileEnd -> {
                state.useFraming = true
                val localCrc = state.fileCrc and 0xffffffffL
                val deviceCrc = parsed.crc32 and 0xffffffffL
                val filename = state.currentFilename.orEmpty()

                if (localCrc != deviceCrc) {
                    val part = partNumberFromFilename(filename)
                    if (part != null && part <= state.fileCompleteCount) {
                        resetCurrentFile(state)
                        return BleTransferFrameResult.FileEndStale(
                            filename = filename,
                            deviceCrc32 = deviceCrc,
                        )
                    }

                    val resync = "%04d.opus".format(state.fileCompleteCount + 1)
                    resetCurrentFile(state)
                    return BleTransferFrameResult.FileEndCrcMismatch(
                        filename = filename,
                        localCrc32 = localCrc,
                        deviceCrc32 = deviceCrc,
                        resyncStartFile = resync,
                    )
                }

                val declaredSize = state.currentFileDeclaredSize
                val bytesThisFile = state.bytesThisFile
                val usedFraming = state.useFraming
                resetCurrentFile(state)
                state.fileCompleteCount += 1

                return BleTransferFrameResult.FileEndOk(
                    filename = filename,
                    localCrc32 = localCrc,
                    deviceCrc32 = deviceCrc,
                    fileCompleteCount = state.fileCompleteCount,
                    declaredFileSize = declaredSize,
                    bytesThisFile = bytesThisFile,
                    usedFraming = usedFraming,
                )
            }
            is ClipFileDataParsed.TransferDone -> {
                state.useFraming = true
                return BleTransferFrameResult.TransferDone(
                    sessionId = parsed.sessionId,
                    fileCount = parsed.fileCount,
                )
            }
        }
    }

    private fun resetCurrentFile(state: BleTransferFrameState) {
        state.currentFilename = null
        state.currentFileDeclaredSize = 0
        state.bytesThisFile = 0
        state.fileCrc = 0
        state.nextSeq = 0
    }
}
