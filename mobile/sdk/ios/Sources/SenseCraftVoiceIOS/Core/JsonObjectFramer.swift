import Foundation

public final class JsonObjectFramer {
    private var buffer = ""

    public init() {}

    public func feed(_ chunk: String) -> [String] {
        guard !chunk.isEmpty else { return [] }
        buffer += chunk
        var output: [String] = []

        while true {
            guard let start = buffer.firstIndex(of: "{") else {
                if buffer.count > 4096 {
                    buffer = String(buffer.suffix(1024))
                }
                return output
            }
            if start != buffer.startIndex {
                buffer = String(buffer[start...])
            }

            guard let end = findJsonObjectEnd(buffer) else { return output }
            let object = String(buffer[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[end...])
            if !object.isEmpty {
                output.append(object)
            }
        }
    }

    private func findJsonObjectEnd(_ s: String) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = s.startIndex

        while index < s.endIndex {
            let ch = s[index]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                index = s.index(after: index)
                continue
            }

            if ch == "\"" {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return s.index(after: index)
                }
            }
            index = s.index(after: index)
        }
        return nil
    }
}

