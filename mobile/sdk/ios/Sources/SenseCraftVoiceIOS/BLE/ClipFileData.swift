import Foundation

public let kClipFrameData: UInt8 = 0x01
public let kClipFrameFileStart: UInt8 = 0x10
public let kClipFrameFileEnd: UInt8 = 0x11
public let kClipFrameTransferDone: UInt8 = 0x12
public let kClipDataHeaderSize = 5

public enum ClipFileDataParsed {
    case raw(Data)
    case data(seq: Int, payload: Data)
    case fileStart(filename: String, fileSize: Int)
    case fileEnd(crc32: UInt32)
    case transferDone(sessionId: String, fileCount: Int)
    case invalid(reason: String)
}

public func parseClipFileDataNotify(_ data: Data) -> ClipFileDataParsed {
    guard !data.isEmpty else { return .invalid(reason: "empty") }
    let bytes = [UInt8](data)

    switch bytes[0] {
    case kClipFrameData:
        guard bytes.count >= kClipDataHeaderSize else {
            return .invalid(reason: "DATA short header len=\(bytes.count)")
        }
        let len = Int(bytes[3]) | (Int(bytes[4]) << 8)
        guard bytes.count == kClipDataHeaderSize + len else {
            return .invalid(reason: "DATA len mismatch total=\(bytes.count) payload=\(len)")
        }
        let seq = Int(bytes[1]) | (Int(bytes[2]) << 8)
        return .data(seq: seq, payload: data.subdata(in: kClipDataHeaderSize..<kClipDataHeaderSize + len))

    case kClipFrameFileStart:
        guard bytes.count >= 3 else {
            return .invalid(reason: "FILE_START short len=\(bytes.count)")
        }
        let fnLen = Int(bytes[1])
        guard bytes.count >= 2 + fnLen + 4 else {
            return .invalid(reason: "FILE_START bad fnLen=\(fnLen) total=\(bytes.count)")
        }
        let nameData = data.subdata(in: 2..<2 + fnLen)
        let filename = String(decoding: nameData, as: UTF8.self)
        let metaOff = 2 + fnLen
        let fileSize =
            Int(bytes[metaOff]) |
            (Int(bytes[metaOff + 1]) << 8) |
            (Int(bytes[metaOff + 2]) << 16) |
            (Int(bytes[metaOff + 3]) << 24)
        return .fileStart(filename: filename, fileSize: fileSize)

    case kClipFrameFileEnd:
        guard bytes.count >= 5 else {
            return .invalid(reason: "FILE_END short len=\(bytes.count)")
        }
        let crc =
            UInt32(bytes[1]) |
            (UInt32(bytes[2]) << 8) |
            (UInt32(bytes[3]) << 16) |
            (UInt32(bytes[4]) << 24)
        return .fileEnd(crc32: crc)

    case kClipFrameTransferDone:
        guard bytes.count >= 3 else {
            return .invalid(reason: "TRANSFER_DONE short len=\(bytes.count)")
        }
        let sidLen = Int(bytes[1])
        guard bytes.count >= 2 + sidLen + 4 else {
            return .invalid(reason: "TRANSFER_DONE bad sidLen=\(sidLen)")
        }
        let sidData = data.subdata(in: 2..<2 + sidLen)
        let sessionId = String(decoding: sidData, as: UTF8.self)
        let off = 2 + sidLen
        let fileCount =
            Int(bytes[off]) |
            (Int(bytes[off + 1]) << 8) |
            (Int(bytes[off + 2]) << 16) |
            (Int(bytes[off + 3]) << 24)
        return .transferDone(sessionId: sessionId, fileCount: fileCount)

    default:
        return .raw(data)
    }
}

