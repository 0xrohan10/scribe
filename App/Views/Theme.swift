import AppKit
import SwiftUI

/// Gray backgrounds, contrasting primary actions, and indigo highlights with light and dark variants.
enum Theme {
    static let background = Color(light: 0xFFFFFF, dark: 0x212121)
    static let sidebar = Color(light: 0xF8F8F7, dark: 0x181818)
    static let surface = Color(light: 0xFFFFFF, dark: 0x2F2F2F)
    /// Background for the user's transcript lines and questions.
    static let bubble = Color(light: 0xF2F2F1, dark: 0x303030)
    static let hover = Color(light: 0xECECEB, dark: 0x2A2A2A)
    static let border = Color(light: 0xE6E6E4, dark: 0x383838)
    static let text = Color(light: 0x0D0D0D, dark: 0xECECEC)
    static let secondary = Color(light: 0x5D5D5B, dark: 0xB4B4B4)
    static let tertiary = Color(light: 0x8F8F8C, dark: 0x8A8A8A)
    /// Primary actions use black in light mode and white in dark mode.
    static let accent = Color(light: 0x0D0D0D, dark: 0xECECEC)
    /// Text and icons drawn on `accent`.
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x0D0D0D)
    /// Timestamps, the focused note's moment, selection.
    static let highlight = Color(light: 0x5B5BD6, dark: 0x9091F2)
    static let recording = Color(light: 0xE5484D, dark: 0xF2555A)
    static let flag = Color(light: 0xD4A017, dark: 0xE8B83A)

    /// Serif font for page titles. Other text uses the system sans-serif font.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

/// Spring animations under 300 ms without overshoot.
enum Motion {
    /// Panel and summary transitions.
    static let standard = Animation.smooth(duration: 0.28)
    /// Note, message, and tag updates.
    static let quick = Animation.smooth(duration: 0.2)
    static let press = Animation.easeOut(duration: 0.12)
}

extension View {
    /// Animates changes to `value`, or cross-fades briefly when Reduce Motion is on.
    func motion(_ animation: Animation = Motion.standard, value: some Equatable) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? .easeOut(duration: 0.15) : animation, value: value)
    }
}

extension AnyTransition {
    /// Moves up 6 points while fading in and removing a 2-point blur. Reduce Motion keeps only the fade.
    static var rise: AnyTransition { .modifier(active: RiseEffect(progress: 0), identity: RiseEffect(progress: 1)) }

    /// Adds scaling from 96% around `anchor` to `.rise`.
    static func rise(from anchor: UnitPoint) -> AnyTransition {
        .modifier(active: RiseEffect(progress: 0, anchor: anchor), identity: RiseEffect(progress: 1, anchor: anchor))
    }
}

private struct RiseEffect: ViewModifier {
    let progress: Double
    var anchor: UnitPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(anchor == nil || reduceMotion ? 1 : 0.96 + 0.04 * progress, anchor: anchor ?? .center)
            .opacity(progress)
            .offset(y: reduceMotion ? 0 : (1 - progress) * 6)
            .blur(radius: reduceMotion ? 0 : (1 - progress) * 2)
    }
}

extension View {
    /// Applies the rise effect when `isShown` becomes true, after `delay`.
    /// Views keep their layout positions during the animation.
    func rise(isShown: Bool, delay: Double = 0) -> some View {
        modifier(RiseEffect(progress: isShown ? 1 : 0)).motion(Motion.standard.delay(delay), value: isShown)
    }
}

/// Scales to 0.97 while pressed.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// A filled capsule button. Uses the accent color by default.
struct CapsuleButtonStyle: ButtonStyle {
    var fill: Color = Theme.accent
    var foreground: Color = Theme.onAccent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(fill.opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// A bordered capsule button for secondary actions.
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Theme.text.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(configuration.isPressed ? Theme.hover : Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// A rounded text-input container with a focus border.
struct ComposerCard<Content: View>: View {
    var isFocused = false
    @ViewBuilder var content: Content

    init(isFocused: Bool = false, @ViewBuilder content: () -> Content) {
        self.isFocused = isFocused
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(isFocused ? Theme.tertiary.opacity(0.6) : Theme.border))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 3)
            .motion(Motion.quick, value: isFocused)
    }
}

/// The round send button inside a composer.
struct SendButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 30, height: 30)
                .background(isEnabled ? Theme.accent : Theme.tertiary.opacity(0.4), in: Circle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!isEnabled)
        .motion(Motion.quick, value: isEnabled)
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            })
    }
}

/// Scribe's mark beside its name. `scripts/make-icons.swift` generates the mark and app icons.
struct ScribeLogo: View {
    var body: some View {
        HStack(spacing: 8) {
            Image("ScribeMark")
                .resizable()
                .frame(width: 15, height: 15)
                .foregroundStyle(Theme.onAccent)
                .accessibilityHidden(true)
                .frame(width: 22, height: 22)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text("Scribe").font(.system(size: 16, weight: .semibold))
        }
        .accessibilityElement(children: .combine)
    }
}
