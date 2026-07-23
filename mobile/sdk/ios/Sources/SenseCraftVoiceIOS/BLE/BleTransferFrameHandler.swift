import Foundation

public final class BleTransferFrameState {
    public var useFraming = false
    public var currentFilename: String?
    public var currentFileDeclaredSize = 0
    public var bytesThisFile = 0
    public var fileCrc: UInt32 = 0
    public var nextSeq = 0
    public var fileCompleteCount = 0

    public init() {}
}

public enum BleTransferFrameResult: Equatable {
    case invalid(reason: String)
    case raw(Data)
    case unexpectedRaw(length: Int)
    case fileStart(filename: String, fileSize: Int)
    case data(
        seq: Int,
        payload: Data,
        duplicateSeq: Bool,
        seqJump: Bool,
        orphanBeforeFileStart: Bool
    )
    case fileEndOk(
        filename: String,
        localCrc32: UInt32,
        deviceCrc32: UInt32,
        fileCompleteCount: Int,
        declaredFileSize: Int,
        bytesThisFile: Int,
        usedFraming: Bool
    )
    case fileEndStale(filename: String, deviceCrc32: UInt32)
    case fileEndCrcMismatch(
        filename: String,
        localCrc32: UInt32,
        deviceCrc32: UInt32,
        resyncStartFile: String
    )
    case transferDone(sessionId: String, fileCount: Int)
}

public enum BleTransferFrameHandler {
    public static func sanitizeFilename(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "part.opus" }

        var safe = ""
        for scalar in trimmed.unicodeScalars {
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 46, 95:
                safe.unicodeScalars.append(scalar)
            case 47, 92:
                safe.append("_")
            default:
                safe.append("_")
            }
        }
        return safe.isEmpty ? "part.opus" : safe
    }

    public static func orphanFilenameBeforeFileStart(
        effectiveStartFile: String?,
        fileCompleteCount: Int
    ) -> String {
        let trimmed = effectiveStartFile?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return trimmed }
        return String(format: "%04d.opus", fileCompleteCount + 1)
    }

    public static func partNumberFromFilename(_ name: String) -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 9, trimmed.hasSuffix(".opus") else { return nil }
        let prefix = String(trimmed.prefix(4))
        guard prefix.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        return Int(prefix)
    }

    public static func handle(
        bytes: Data,
        state: BleTransferFrameState,
        effectiveStartFile: String? = nil
    ) -> BleTransferFrameResult {
        let parsed = parseClipFileDataNotify(bytes)

        switch parsed {
        case .invalid(let reason):
            return .invalid(reason: reason)

        case .raw(let raw):
            if state.useFraming {
                return .unexpectedRaw(length: raw.count)
            }
            return .raw(raw)

        case .fileStart(let filename, let fileSize):
            state.useFraming = true
            state.currentFilename = filename
            state.currentFileDeclaredSize = fileSize
            state.bytesThisFile = 0
            state.fileCrc = 0
            state.nextSeq = 0
            return .fileStart(filename: filename, fileSize: fileSize)

        case .data(let seq, let payload):
            state.useFraming = true
            var orphanBeforeFileStart = false
            if state.currentFilename == nil {
                orphanBeforeFileStart = true
                let guess = orphanFilenameBeforeFileStart(
                    effectiveStartFile: effectiveStartFile,
                    fileCompleteCount: state.fileCompleteCount
                )
                state.currentFilename = sanitizeFilename(guess)
                state.nextSeq = seq
                state.fileCrc = 0
            }

            var duplicateSeq = false
            var seqJump = false
            if seq != state.nextSeq {
                if seq < state.nextSeq {
                    duplicateSeq = true
                    return .data(
                        seq: seq,
                        payload: payload,
                        duplicateSeq: true,
                        seqJump: false,
                        orphanBeforeFileStart: orphanBeforeFileStart
                    )
                }
                seqJump = true
                state.nextSeq = seq
            }
            state.nextSeq = seq + 1

            if state.currentFileDeclaredSize > 0 {
                state.bytesThisFile += payload.count
            }
            state.fileCrc = crc32IEEE(payload, seed: state.fileCrc)

            return .data(
                seq: seq,
                payload: payload,
                duplicateSeq: duplicateSeq,
                seqJump: seqJump,
                orphanBeforeFileStart: orphanBeforeFileStart
            )

        case .fileEnd(let crc32):
            state.useFraming = true
            let localCrc = state.fileCrc
            let filename = state.currentFilename ?? ""

            if localCrc != crc32 {
                if let part = partNumberFromFilename(filename),
                   part <= state.fileCompleteCount {
                    resetCurrentFile(state)
                    return .fileEndStale(filename: filename, deviceCrc32: crc32)
                }

                let resync = String(format: "%04d.opus", state.fileCompleteCount + 1)
                resetCurrentFile(state)
                return .fileEndCrcMismatch(
                    filename: filename,
                    localCrc32: localCrc,
                    deviceCrc32: crc32,
                    resyncStartFile: resync
                )
            }

            let declaredSize = state.currentFileDeclaredSize
            let bytesThisFile = state.bytesThisFile
            let usedFraming = state.useFraming
            resetCurrentFile(state)
            state.fileCompleteCount += 1

            return .fileEndOk(
                filename: filename,
                localCrc32: localCrc,
                deviceCrc32: crc32,
                fileCompleteCount: state.fileCompleteCount,
                declaredFileSize: declaredSize,
                bytesThisFile: bytesThisFile,
                usedFraming: usedFraming
            )

        case .transferDone(let sessionId, let fileCount):
            state.useFraming = true
            return .transferDone(sessionId: sessionId, fileCount: fileCount)
        }
    }

    private static func resetCurrentFile(_ state: BleTransferFrameState) {
        state.currentFilename = nil
        state.currentFileDeclaredSize = 0
        state.bytesThisFile = 0
        state.fileCrc = 0
        state.nextSeq = 0
    }
}
