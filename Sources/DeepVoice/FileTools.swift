import Foundation
import os

private let log = Logger(subsystem: "com.thebrownproject.deepvoice", category: "FileTools")

private let maxReadBytes = 1_048_576 // 1MB
private let homePath = FileManager.default.homeDirectoryForCurrentUser.path

private let sensitiveRelativeDirs: Set<String> = [".ssh", ".gnupg"]

private let protectedWritePrefixes = [
    "/etc", "/usr", "/bin", "/sbin", "/System", "/Library", "/boot", "/proc",
]

enum FileToolError: Error, LocalizedError {
    case missingArgument(String)
    case blocked(String)
    case notFound(String)
    case isDirectory(String)
    case tooLarge(Int)
    case permissionDenied(String)
    case ioError(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let arg): return "Missing required argument: \(arg)"
        case .blocked(let reason): return "Blocked: \(reason)"
        case .notFound(let path): return "File not found: \(path)"
        case .isDirectory(let path): return "Path is a directory: \(path)"
        case .tooLarge(let bytes): return "File too large (\(bytes) bytes, max \(maxReadBytes))"
        case .permissionDenied(let path): return "Permission denied: \(path)"
        case .ioError(let msg): return msg
        }
    }
}

// MARK: - Path validation

private func resolveUserPath(_ raw: String) -> String {
    let expanded = NSString(string: raw).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded).standardized
    if !raw.hasPrefix("/") && !raw.hasPrefix("~") {
        return URL(fileURLWithPath: homePath).appendingPathComponent(raw).standardized.path
    }
    return url.path
}

private func validatePath(_ rawPath: String, tool: String, allowWrite: Bool = false) -> (error: String?, resolved: String) {
    let resolved = resolveUserPath(rawPath)

    if resolved != homePath && !resolved.hasPrefix(homePath + "/") {
        return (formatError(tool, .blocked("path \(resolved) is outside home directory")), resolved)
    }
    for dir in sensitiveRelativeDirs {
        let sensitive = homePath + "/" + dir
        if resolved == sensitive || resolved.hasPrefix(sensitive + "/") {
            return (formatError(tool, .blocked("cannot access sensitive directory")), resolved)
        }
    }
    if allowWrite {
        for prefix in protectedWritePrefixes {
            if resolved == prefix || resolved.hasPrefix(prefix + "/") {
                return (formatError(tool, .blocked("cannot write to protected path \(resolved)")), resolved)
            }
        }
    }
    return (nil, resolved)
}

// MARK: - Handlers

func handleFileRead(_ arguments: String) async throws -> String {
    guard let data = arguments.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rawPath = obj["path"] as? String, !rawPath.isEmpty else {
        return formatError("file_read", .missingArgument("path"))
    }

    let (error, resolved) = validatePath(rawPath, tool: "file_read")
    if let error { return error }

    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: resolved, isDirectory: &isDir) else {
        return formatError("file_read", .notFound(resolved))
    }
    if isDir.boolValue {
        return formatError("file_read", .isDirectory(resolved))
    }

    do {
        let attrs = try fm.attributesOfItem(atPath: resolved)
        let size = (attrs[.size] as? Int) ?? 0

        if size > maxReadBytes {
            let handle = FileHandle(forReadingAtPath: resolved)
            defer { handle?.closeFile() }
            guard let handle else {
                return formatError("file_read", .permissionDenied(resolved))
            }
            let readData = handle.readData(ofLength: maxReadBytes)
            let text = String(data: readData, encoding: .utf8)
                ?? String(data: readData, encoding: .ascii)
                ?? "(binary content)"
            return text + "\n... truncated (\(size) bytes total, showing first \(maxReadBytes))"
        }

        let contents = try String(contentsOfFile: resolved, encoding: .utf8)
        log.info("file_read: \(resolved) (\(size) bytes)")
        return contents
    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
        return formatError("file_read", .permissionDenied(resolved))
    } catch {
        return formatError("file_read", .ioError(error.localizedDescription))
    }
}

func handleFileWrite(_ arguments: String) async throws -> String {
    guard let data = arguments.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rawPath = obj["path"] as? String, !rawPath.isEmpty else {
        return formatError("file_write", .missingArgument("path"))
    }
    guard let content = obj["content"] as? String else {
        return formatError("file_write", .missingArgument("content"))
    }

    let (error, resolved) = validatePath(rawPath, tool: "file_write", allowWrite: true)
    if let error { return error }

    let fm = FileManager.default
    let parentDir = URL(fileURLWithPath: resolved).deletingLastPathComponent().path

    do {
        if !fm.fileExists(atPath: parentDir) {
            try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }

        guard let writeData = content.data(using: .utf8) else {
            return formatError("file_write", .ioError("Failed to encode content as UTF-8"))
        }
        try writeData.write(to: URL(fileURLWithPath: resolved))

        let byteCount = writeData.count
        log.info("file_write: \(resolved) (\(byteCount) bytes)")
        return "Wrote \(byteCount) bytes to \(resolved)"
    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError {
        return formatError("file_write", .permissionDenied(resolved))
    } catch {
        return formatError("file_write", .ioError(error.localizedDescription))
    }
}

private func formatError(_ tool: String, _ error: FileToolError) -> String {
    log.error("Error in \(tool): \(error.localizedDescription)")
    return "Error in \(tool): \(error.localizedDescription)"
}
