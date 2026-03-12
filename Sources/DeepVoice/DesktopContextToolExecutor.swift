import AppKit
import CoreGraphics
import Foundation

/// Extracted from WebSocketClient.swift for standalone use.
protocol AppToolExecutor: AnyObject {
    func execute(tool: String, args: [String: Any]) async throws -> [String: Any]
}

enum DesktopContextToolError: LocalizedError {
    case missingFrontmostApplication
    case displayCaptureUnavailable
    case bitmapContextUnavailable
    case jpegEncodingFailed
    case unsupportedTool(String)

    var errorDescription: String? {
        switch self {
        case .missingFrontmostApplication:
            "No frontmost application was available."
        case .displayCaptureUnavailable:
            "Display capture was unavailable."
        case .bitmapContextUnavailable:
            "Failed to create the screenshot bitmap context."
        case .jpegEncodingFailed:
            "Failed to encode the display screenshot as JPEG."
        case .unsupportedTool(let tool):
            "Unsupported app tool: \(tool)"
        }
    }
}

private let maxCaptureDimension = 1440
private let captureCompressionFactor: CGFloat = 0.55

@MainActor
final class DesktopContextToolExecutor: AppToolExecutor {
    func execute(tool: String, args: [String: Any]) async throws -> [String: Any] {
        _ = args
        switch tool {
        case "frontmost_app_context":
            return try frontmostAppContext()
        case "capture_display":
            return try captureDisplay()
        default:
            throw DesktopContextToolError.unsupportedTool(tool)
        }
    }

    private func frontmostAppContext() throws -> [String: Any] {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw DesktopContextToolError.missingFrontmostApplication
        }

        var payload: [String: Any] = [
            "app_name": app.localizedName ?? "Unknown",
            "bundle_id": app.bundleIdentifier ?? "",
            "process_id": Int(app.processIdentifier),
        ]

        if let windowTitle = frontmostWindowTitle(for: app.processIdentifier) {
            payload["window_title"] = windowTitle
        }
        payload.merge(bestEffortDocumentContext(for: app)) { _, new in new }

        return payload
    }

    private func captureDisplay() throws -> [String: Any] {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw DesktopContextToolError.displayCaptureUnavailable
        }

        let description = screen.deviceDescription
        guard let screenNumber = description[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw DesktopContextToolError.displayCaptureUnavailable
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        guard let image = CGDisplayCreateImage(displayID) else {
            throw DesktopContextToolError.displayCaptureUnavailable
        }

        let originalWidth = image.width
        let originalHeight = image.height
        let targetSize = scaledSize(width: originalWidth, height: originalHeight)
        guard let jpegData = jpegData(from: image, targetSize: targetSize) else {
            throw DesktopContextToolError.jpegEncodingFailed
        }

        return [
            "display_id": Int(displayID),
            "width": Int(targetSize.width),
            "height": Int(targetSize.height),
            "original_width": originalWidth,
            "original_height": originalHeight,
            "byte_count": jpegData.count,
            "mime_type": "image/jpeg",
            "image_base64": jpegData.base64EncodedString(),
        ]
    }

    private func scaledSize(width: Int, height: Int) -> NSSize {
        let longestEdge = max(width, height)
        guard longestEdge > maxCaptureDimension else {
            return NSSize(width: width, height: height)
        }

        let scale = CGFloat(maxCaptureDimension) / CGFloat(longestEdge)
        let scaledWidth = max(Int((CGFloat(width) * scale).rounded(.down)), 1)
        let scaledHeight = max(Int((CGFloat(height) * scale).rounded(.down)), 1)
        return NSSize(width: scaledWidth, height: scaledHeight)
    }

    private func jpegData(from image: CGImage, targetSize: NSSize) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(Int(targetSize.width), 1),
            pixelsHigh: max(Int(targetSize.height), 1),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        bitmap.size = targetSize

        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }

        let sourceSize = NSSize(width: image.width, height: image.height)
        let imageRect = NSRect(origin: .zero, size: sourceSize)
        let targetRect = NSRect(origin: .zero, size: targetSize)
        let nsImage = NSImage(cgImage: image, size: sourceSize)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        nsImage.draw(in: targetRect, from: imageRect, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: captureCompressionFactor]
        )
    }

    private func frontmostWindowTitle(for processID: pid_t) -> String? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in windowInfo {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == processID else {
                continue
            }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }

            if let title = info[kCGWindowName as String] as? String, !title.isEmpty {
                return title
            }
            if let ownerName = info[kCGWindowOwnerName as String] as? String, !ownerName.isEmpty {
                return ownerName
            }
        }

        return nil
    }

    private func bestEffortDocumentContext(for app: NSRunningApplication) -> [String: Any] {
        guard let bundleID = app.bundleIdentifier else { return [:] }

        if let currentURL = currentBrowserURL(bundleID: bundleID) {
            return ["current_url": currentURL]
        }
        if let currentFilePath = currentFilePath(bundleID: bundleID) {
            return ["current_file_path": currentFilePath]
        }
        return [:]
    }

    private func currentBrowserURL(bundleID: String) -> String? {
        let script: String?
        switch bundleID {
        case "com.apple.Safari":
            script = """
            tell application id "\(bundleID)"
                if (count of windows) = 0 then return ""
                return URL of current tab of front window
            end tell
            """
        case "com.google.Chrome",
             "com.brave.Browser",
             "com.microsoft.edgemac",
             "org.chromium.Chromium",
             "company.thebrowser.Browser":
            script = """
            tell application id "\(bundleID)"
                if (count of windows) = 0 then return ""
                return URL of active tab of front window
            end tell
            """
        default:
            script = nil
        }

        guard let script else { return nil }
        return runAppleScript(script)
    }

    private func currentFilePath(bundleID: String) -> String? {
        let script: String?
        switch bundleID {
        case "com.apple.finder":
            script = """
            tell application id "\(bundleID)"
                if (count of Finder windows) = 0 then return ""
                return POSIX path of (target of front Finder window as alias)
            end tell
            """
        default:
            script = nil
        }

        guard let script else { return nil }
        return runAppleScript(script)
    }

    private func runAppleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let stringValue = descriptor.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stringValue.isEmpty {
            return stringValue
        }
        if let errorInfo {
            NSLog("DesktopContextToolExecutor AppleScript error: %@", errorInfo)
        }
        return nil
    }
}
