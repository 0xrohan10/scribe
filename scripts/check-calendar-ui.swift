#!/usr/bin/env swift
import AppKit
import ApplicationServices

/// Runs only the Debug app's fake-provider mode. It never starts Google sign-in.
enum CalendarUICheck {
    @MainActor static func check() async throws {
        guard AXIsProcessTrusted() else {
            throw CheckError("Grant your terminal Accessibility access before running this check.")
        }
        let app = CommandLine.arguments.dropFirst().first ?? "build/DerivedData/Build/Products/Debug/Scribe.app"
        let directory = URL.temporaryDirectory.appending(path: "opencode/calendar-ui-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let process = Process()
        process.executableURL = URL(filePath: app).appending(path: "Contents/MacOS/Scribe")
        process.arguments = ["--ui-testing", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        _ = try await wait("Debug UI-testing mode to create its isolated database") {
            FileManager.default.fileExists(atPath: directory.appending(path: "scribe.sqlite").path) ? true : nil
        }

        let root = Element(ref: AXUIElementCreateApplication(process.processIdentifier))
        AXUIElementSetMessagingTimeout(root.ref, 1)
        func elements() -> [Element] {
            let windows: [AXUIElement] = root.attribute(kAXWindowsAttribute) ?? []
            let menu: AXUIElement? = root.attribute("AXExtrasMenuBar")
            return (windows + [menu].compactMap { $0 }).flatMap { Element(ref: $0).descendants() }
        }
        func find(_ name: String) -> Element? { elements().first { $0.matches(name) } }

        let menu = try await wait("Scribe menu bar item") {
            (root.attribute("AXExtrasMenuBar") as AXUIElement?).map { Element(ref: $0) }.flatMap { $0.children.first }
        }
        // Opening an accessibility menu can time out while the menu remains open.
        try? menu.press()
        let settings = try await wait("Settings menu item") { find("Settings…") }
        try settings.press()

        let connect = try await wait("Add Google account button") { find("calendars.connect") }
        guard !connect.isEnabled else { throw CheckError("Calendar configuration leaked from an earlier UI-test launch.") }
        let field = try await wait("Desktop client ID setup field") { find("calendars.clientID") }
        try root.set(kAXFrontmostAttribute, kCFBooleanTrue)
        try field.set(kAXFocusedAttribute, kCFBooleanTrue)
        for scalar in "ui-test.apps.googleusercontent.com".utf16 {
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown) else {
                    throw CheckError("Could not create a keyboard event.")
                }
                event.keyboardSetUnicodeString(stringLength: 1, unicodeString: [scalar])
                event.postToPid(process.processIdentifier)
            }
            try await Task.sleep(for: .milliseconds(8))
        }
        let save = try await wait("enabled Save configuration button") {
            find("Save configuration").flatMap { $0.isEnabled ? $0 : nil }
        }
        try save.press()
        _ = try await wait("Add Google account to become enabled after Save") {
            find("calendars.connect").flatMap { $0.isEnabled ? $0 : nil }
        }

        let upcoming = try await wait("Upcoming sidebar item") { find("sidebar.upcoming") }
        try upcoming.press()
        let refresh = try await wait("Upcoming refresh button") { find("calendars.refresh") }
        guard !refresh.isEnabled else { throw CheckError("Refresh is enabled without a connected account.") }
        let calendarSettings = try await wait("Calendar settings link") { find("Calendar settings") }
        try calendarSettings.press()
        let restoredField = try await wait("saved Desktop client ID") { find("calendars.clientID") }
        guard restoredField.attribute(kAXValueAttribute) as String? == "ui-test.apps.googleusercontent.com" else {
            throw CheckError("Calendar configuration was lost when changing pages.")
        }
        print("PASS: clean test preferences, OAuth setup, configuration save, Upcoming empty state, and Settings navigation.")
    }

    @MainActor private static func wait<T>(_ description: String, _ check: () -> T?) async throws -> T {
        let deadline = Date.now.addingTimeInterval(10)
        repeat {
            if let value = check() { return value }
            try await Task.sleep(for: .milliseconds(100))
        } while Date.now < deadline
        throw CheckError("Timed out waiting for \(description).")
    }
}

private struct CheckError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct Element {
    let ref: AXUIElement
    func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
    var children: [Element] { (attribute(kAXChildrenAttribute) as [AXUIElement]? ?? []).map { Element(ref: $0) } }
    var isEnabled: Bool { attribute(kAXEnabledAttribute) ?? false }
    func descendants(depth: Int = 0) -> [Element] {
        guard depth < 40 else { return [] }
        return [self] + children.flatMap { $0.descendants(depth: depth + 1) }
    }
    func matches(_ name: String) -> Bool {
        [kAXIdentifierAttribute, kAXDescriptionAttribute, kAXTitleAttribute].contains { (attribute($0) as String?) == name }
    }
    func press() throws {
        guard AXUIElementPerformAction(ref, kAXPressAction as CFString) == .success else { throw CheckError("Could not activate control.") }
    }
    func set(_ name: String, _ value: CFTypeRef) throws {
        guard AXUIElementSetAttributeValue(ref, name as CFString, value) == .success else { throw CheckError("Could not set field value.") }
    }
}

Task { @MainActor in
    do {
        try await CalendarUICheck.check()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
dispatchMain()
