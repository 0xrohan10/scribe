import AppKit
import ApplicationServices
import Core
import Darwin
import Foundation

public struct DetectedMeeting: Sendable, Hashable {
    public var app: MeetingApp
    public var pid: pid_t
    public var bundleID: String?

    public init(app: MeetingApp, pid: pid_t, bundleID: String?) {
        self.app = app
        self.pid = pid
        self.bundleID = bundleID
    }
}

/// Checks whether a meeting of this kind is in progress. Polled while the mic is in use.
public protocol MeetingProbe: Sendable {
    func probe() async -> DetectedMeeting?
}

/// Zoom spawns `CptHost` only while a meeting is in progress.
public struct ZoomProbe: MeetingProbe {
    public init() {}

    public func probe() async -> DetectedMeeting? {
        guard let hostPID = Processes.pids(named: "CptHost").first else { return nil }
        let zoom = NSRunningApplication.runningApplications(withBundleIdentifier: "us.zoom.xos").first
        return DetectedMeeting(app: .zoom, pid: zoom?.processIdentifier ?? hostPID, bundleID: zoom?.bundleIdentifier ?? "us.zoom.xos")
    }
}

/// Matches window titles via the Accessibility API. Needs Accessibility permission; returns nil without it.
public struct WindowTitleProbe: MeetingProbe {
    public let app: MeetingApp
    public let bundleIDs: Set<String>
    public let matches: @Sendable (String) -> Bool

    public init(app: MeetingApp, bundleIDs: Set<String>, matches: @escaping @Sendable (String) -> Bool) {
        self.app = app
        self.bundleIDs = bundleIDs
        self.matches = matches
    }

    public func probe() async -> DetectedMeeting? {
        guard AXIsProcessTrusted() else { return nil }
        for running in NSWorkspace.shared.runningApplications {
            guard let bundleID = running.bundleIdentifier, bundleIDs.contains(bundleID) else { continue }
            let pid = running.processIdentifier
            if Accessibility.windowTitles(pid: pid).contains(where: matches) {
                return DetectedMeeting(app: app, pid: pid, bundleID: bundleID)
            }
        }
        return nil
    }

    /// New and classic Teams. In-call windows are titled e.g. "Meeting with Ana | Microsoft Teams" or
    /// "Call with …"; the main window is "Calendar | …", "Chat | …".
    public static let teams = WindowTitleProbe(app: .teams, bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"]) { title in
        title.range(of: #"\b(Meeting|Call)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            && !title.localizedCaseInsensitiveContains("Calendar")
    }

    /// Meet tabs are titled "Meet - abc-defg-hij" / "Meet – Weekly sync". AX only exposes each window's
    /// active tab, so a backgrounded Meet tab is missed; the browser-extension detector will cover that.
    public static let meet = WindowTitleProbe(app: .meet, bundleIDs: browserBundleIDs) { title in
        title.range(of: #"^Meet [-–—] "#, options: .regularExpression) != nil || title.contains("meet.google.com")
    }

    public static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.apple.Safari",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser", "company.thebrowser.dia",
        "org.mozilla.firefox", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
}

public enum Accessibility {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "allow Accessibility" prompt if not yet trusted.
    @discardableResult
    public static func requestTrust() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func windowTitles(pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
            let windows = windows as? [AXUIElement]
        else { return [] }
        return windows.compactMap { window in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            return title as? String
        }
    }
}

enum Processes {
    /// PIDs whose short process name (`p_comm`) equals `name`.
    static func pids(named name: String) -> [pid_t] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var buffer = [CChar](repeating: 0, count: 256)
        return pids.prefix(Int(max(0, count))).filter { pid in
            let length = proc_name(pid, &buffer, UInt32(buffer.count))
            return length > 0 && String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) == name
        }
    }
}
