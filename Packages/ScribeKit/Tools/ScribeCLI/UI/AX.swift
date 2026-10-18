import AppKit
import ApplicationServices
import ArgumentParser

/// A thin wrapper over one accessibility element of the app under test.
struct Element {
    let ref: AXUIElement

    func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    var role: String { attribute(kAXRoleAttribute) ?? "?" }
    var identifier: String? { attribute(kAXIdentifierAttribute) }
    var title: String? { attribute(kAXTitleAttribute) }
    var label: String? { attribute(kAXDescriptionAttribute) }
    var value: String? {
        guard let value: Any = attribute(kAXValueAttribute) else { return nil }
        return value as? String ?? (value as? NSNumber)?.stringValue
    }
    var isEnabled: Bool { attribute(kAXEnabledAttribute) ?? true }
    var children: [Element] { (attribute(kAXChildrenAttribute) as [AXUIElement]?)?.map(Element.init) ?? [] }
    var window: Element? { (attribute(kAXWindowAttribute) as AXUIElement?).map(Element.init) }

    /// Every element below this one, depth first.
    func descendants(maxDepth: Int = 40) -> [Element] {
        guard maxDepth > 0 else { return [] }
        return children.flatMap { [$0] + $0.descendants(maxDepth: maxDepth - 1) }
    }

    /// Matches an identifier (`notes.add`), a title (`Start Recording`) or an accessibility label.
    func matches(_ query: String) -> Bool {
        identifier == query || title == query || label == query
    }

    /// The visible text of this element and everything in it, e.g. a transcript row's time, speaker and words.
    var text: String {
        ([self] + descendants()).compactMap { e in [e.title, e.label, e.value].compactMap { $0 }.first { !$0.isEmpty } }
            .joined(separator: " ")
    }

    func perform(_ action: String) throws {
        let result = AXUIElementPerformAction(ref, action as CFString)
        guard result == .success else { throw UIError("\(action) on \(summary) failed (\(result.rawValue))") }
    }

    func set(_ attribute: String, _ value: CFTypeRef) throws {
        let result = AXUIElementSetAttributeValue(ref, attribute as CFString, value)
        guard result == .success else { throw UIError("Setting \(attribute) on \(summary) failed (\(result.rawValue))") }
    }

    /// One line for `tree` and error messages: role, #identifier and text.
    var summary: String {
        var parts = [role]
        if let identifier { parts.append("#\(identifier)") }
        for (key, text) in [("title", title), ("label", label), ("value", value)] {
            if let text, !text.isEmpty { parts.append("\(key)=\"\(text.count > 80 ? text.prefix(77) + "…" : text)\"") }
        }
        if !isEnabled { parts.append("(disabled)") }
        return parts.joined(separator: " ")
    }
}

struct UIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The running Scribe under test.
struct TestedApp {
    let pid: pid_t
    let root: Element

    init(pid: pid_t) {
        self.pid = pid
        root = Element(ref: AXUIElementCreateApplication(pid))
        // A menu opened by AXPress blocks the call until it closes; don't wait the default 6 s for that.
        AXUIElementSetMessagingTimeout(root.ref, 1)
    }

    var windows: [Element] { (root.attribute(kAXWindowsAttribute) as [AXUIElement]?)?.map(Element.init) ?? [] }
    var statusItem: Element? {
        (root.attribute("AXExtrasMenuBar") as AXUIElement?).map(Element.init)?.children.first
    }

    /// Searches the windows (with their sheets and open menus) and the menu bar item's open menu.
    func all(_ query: String) -> [Element] {
        let scopes = windows + [statusItem].compactMap { $0 }
        return scopes.flatMap { [$0] + $0.descendants() }.filter { $0.matches(query) }
    }

    func find(_ query: String) throws -> Element {
        guard let element = all(query).first else { throw UIError("Nothing matches “\(query)”") }
        return element
    }

    /// Polls until `condition` returns a value, or fails after `timeout`.
    func wait<T>(_ what: String, timeout: Double = 10, _ condition: () throws -> T?) async throws -> T {
        let deadline = Date.now.addingTimeInterval(timeout)
        var lastError: Error?
        repeat {
            do {
                if let value = try condition() { return value }
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(200))
        } while Date.now < deadline
        throw UIError("Timed out after \(Int(timeout))s waiting for \(what)\(lastError.map { ": \($0)" } ?? "")")
    }

    func press(_ query: String) throws {
        let element = try find(query)
        guard element.isEnabled else { throw UIError("\(element.summary) is disabled") }
        try element.perform(kAXPressAction)
    }

    /// Clicks the menu bar item, then the item titled `title` in its menu.
    func menu(_ title: String) async throws {
        guard let item = statusItem else { throw UIError("Scribe's menu bar item isn't there") }
        try? item.perform(kAXPressAction)  // Returns an error once the timeout passes, though the menu is open.
        let entry = try await wait("menu item “\(title)”", timeout: 3) { item.descendants().first { $0.role == kAXMenuItemRole && $0.title == title } }
        try entry.perform(kAXPressAction)
    }

    /// Brings the element's window to the front, focuses the element and types into it like a keyboard would.
    func type(_ text: String, into element: Element, submit: Bool = false) async throws {
        try focus(element)
        for scalar in text.utf16 {
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown)!
                event.keyboardSetUnicodeString(stringLength: 1, unicodeString: [scalar])
                event.postToPid(pid)
            }
            try await Task.sleep(for: .milliseconds(8))
        }
        if submit {
            for keyDown in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: keyDown)!.postToPid(pid) }  // Return
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func focus(_ element: Element) throws {
        try root.set(kAXFrontmostAttribute, kCFBooleanTrue)
        try? element.window?.perform(kAXRaiseAction)  // Best effort; some SwiftUI windows refuse it.
        try element.set(kAXFocusedAttribute, kCFBooleanTrue)
    }
}

func requireAccessibility() throws {
    // The value of kAXTrustedCheckOptionPrompt, which Swift 6 won't read as a global var.
    guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
        throw ValidationError(
            "This terminal needs Accessibility access to drive Scribe: System Settings ▸ Privacy & Security ▸ Accessibility, then run again.")
    }
}
