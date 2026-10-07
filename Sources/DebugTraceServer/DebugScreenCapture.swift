import DebugTrace
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// `_screenshot` and `_screen`: what the app is showing, for "what does the broken
/// view look like" without a person describing it.
///
/// Both are queries that the server gates with an on-device prompt on every call (or
/// once for 15 minutes, the person's choice): a screen shows whatever is on it. They are
/// not `releaseSafe`, so the confidential profile and release traces never carry them,
/// and the server does not register them in a release build at all.
enum DebugScreenCapture {
    static let maxElements = 2000
    static let maxDepth = 40
    static let maxTextLength = 200

    @MainActor
    static var endpoints: [DebugEndpoint] {
        [screenshot, screen]
    }

    // MARK: _screenshot

    @MainActor
    static var screenshot: DebugEndpoint {
        .raw(
            "_screenshot", kind: .query,
            "A PNG of one of the app's windows as it is drawn now. `window` is an index from `_screen` (0 is the first visible window); `scale` shrinks or enlarges it. Draws the window's layers, so 2D content (SwiftUI, UIKit) is captured; content a renderer composites itself (RealityKit, Metal, an immersive space) may come back blank, and a visionOS window has no backdrop of its own (see `background`). The person at the device is asked before each capture, or once for 15 minutes.",
            parameters: [
                .integer("window", "index of the window, as listed by _screen", default: 0, range: 0...32),
                .number("scale", "pixels per point", default: 1, range: 0.25...3),
                .string("background", "what to draw behind the window: its glass or clear areas have no colour of their own, so white text on a transparent window would vanish on a white page. auto is dark on visionOS and transparent elsewhere", default: "auto", choices: ["auto", "dark", "light", "transparent"]),
            ],
            trace: .never,
            timeout: .seconds(20)
        ) { arguments in
            let windows = visibleWindows()
            let index = arguments.int("window") ?? 0
            guard windows.indices.contains(index) else {
                throw DebugError.invalidArgument("there is no window \(index): \(windows.count) visible",
                                                 hint: windows.isEmpty
                                                     ? "the app has no visible window (an immersive-only space has none); try _screen"
                                                     : "use window=0…\(windows.count - 1); _screen lists them")
            }
            guard let png = pngData(of: windows[index], scale: arguments.double("scale") ?? 1, background: arguments.string("background") ?? "auto") else {
                throw DebugError(.unavailable, "the window could not be drawn",
                                 hint: "its content may be drawn by a compositor that draws no hierarchy; try _screen for its text")
            }
            return .binary(png, contentType: "image/png", filename: "screenshot-window\(index).png")
        }
    }

    // MARK: _screen

    struct Frame: Encodable, Sendable { let x: Double, y: Double, width: Double, height: Double }

    struct Element: Encodable, Sendable {
        var kind: String
        var label: String?
        var value: String?
        var hint: String?
        var traits: [String]?
        var frame: Frame?
        var children: [Element]?
    }

    struct WindowTree: Encodable, Sendable {
        let index: Int
        let frame: Frame
        let isKey: Bool
        let elements: [Element]
        let truncated: Bool
    }

    struct ScreenReport: Encodable, Sendable {
        let windows: [WindowTree]
        let note: String
    }

    @MainActor
    static var screen: DebugEndpoint {
        .query(
            "_screen",
            "The text and layout of what the app shows, as the accessibility tree: per visible window, each element's label, value, hint, traits and frame (in window points), nested as the app nests them. Shows which views exist, what they say and where they sit; a view with no accessibility content (decoration, an image without a label) does not appear. Pair with _screenshot to see it. The person at the device is asked before each call, or once for 15 minutes.",
            trace: .never,
            timeout: .seconds(20)
        ) { _ in
            var budget = maxElements
            let trees = visibleWindows().enumerated().map { index, window -> WindowTree in
                let elements = describe(window, depth: 0, budget: &budget)
                return WindowTree(index: index, frame: frame(bounds(of: window)), isKey: isKey(window), elements: elements, truncated: budget <= 0)
            }
            return ScreenReport(windows: trees, note: trees.isEmpty
                ? "the app has no visible window"
                : "labels and values are what an assistive technology would read; frames are in points")
        }
    }

    static func text(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.count > maxTextLength ? String(raw.prefix(maxTextLength)) + "…" : raw
    }

    static func frame(_ rect: CGRect) -> Frame {
        Frame(x: rect.origin.x.rounded(), y: rect.origin.y.rounded(), width: rect.width.rounded(), height: rect.height.rounded())
    }
}

// MARK: - UIKit (iOS, tvOS, visionOS)

#if canImport(UIKit)
extension DebugScreenCapture {
    @MainActor
    static func visibleWindows() -> [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isHidden && $0.bounds.width > 0 }
    }

    @MainActor static func isKey(_ window: UIWindow) -> Bool { window.isKeyWindow }
    @MainActor static func bounds(of window: UIWindow) -> CGRect { window.bounds }

    @MainActor
    static func pngData(of window: UIWindow, scale: Double, background: String) -> Data? {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = scale
        format.opaque = false
        #if os(visionOS)
        let fill: UIColor? = background == "light" ? UIColor(white: 0.95, alpha: 1)
            : (background == "transparent" ? nil : UIColor(white: 0.16, alpha: 1))
        #else
        let fill: UIColor? = background == "light" ? UIColor(white: 0.95, alpha: 1)
            : (background == "dark" ? UIColor(white: 0.16, alpha: 1) : nil)
        #endif
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        return renderer.pngData { context in
            if let fill {
                fill.setFill()
                context.fill(window.bounds)
            }
            #if os(visionOS)
            // drawHierarchy comes back blank for a visionOS window (measured on a Vision Pro,
            // xrTimer, 2026-10-07): its content is rendered by the system, not drawn into the
            // view. Rendering the layer tree works.
            window.layer.render(in: context.cgContext)
            #else
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            #endif
        }
    }

    /// Walks views the way an assistive technology would: an element is read, a view
    /// with `accessibilityElements` is asked for them, any other view is walked through.
    @MainActor
    static func describe(_ object: Any, depth: Int, budget: inout Int) -> [Element] {
        guard depth < maxDepth, budget > 0 else { return [] }
        if let view = object as? UIView, view.isHidden || view.alpha == 0 { return [] }
        let isElement = (object as? NSObject)?.isAccessibilityElement ?? false
        var children: [Element] = []
        if let view = object as? UIView, !isElement {
            let declared = view.accessibilityElements ?? []
            let sources: [Any] = declared.isEmpty ? view.subviews : declared
            for source in sources {
                children += describe(source, depth: depth + 1, budget: &budget)
            }
        } else if let container = object as? NSObject, !isElement, let declared = container.accessibilityElements {
            for source in declared { children += describe(source, depth: depth + 1, budget: &budget) }
        }
        guard isElement, let element = object as? NSObject else { return children }
        budget -= 1
        return [Element(kind: String(describing: type(of: element)),
                        label: text(element.accessibilityLabel), value: text(element.accessibilityValue),
                        hint: text(element.accessibilityHint), traits: traitNames(element.accessibilityTraits),
                        frame: frame(windowFrame(of: element)), children: children.isEmpty ? nil : children)]
    }

    /// A UIKit view reports in its window's points. A SwiftUI element is not a view: it reports
    /// the frame the system gives it, which is the same space for a full-window app.
    @MainActor
    static func windowFrame(of element: NSObject) -> CGRect {
        if let view = element as? UIView { return view.convert(view.bounds, to: nil) }
        return element.accessibilityFrame
    }

    static func traitNames(_ traits: UIAccessibilityTraits) -> [String]? {
        let known: [(UIAccessibilityTraits, String)] = [
            (.button, "button"), (.link, "link"), (.header, "header"), (.image, "image"), (.staticText, "text"),
            (.selected, "selected"), (.notEnabled, "disabled"), (.adjustable, "adjustable"), (.searchField, "searchField"),
            (.updatesFrequently, "updatesFrequently"), (.keyboardKey, "keyboardKey"), (.tabBar, "tabBar"),
        ]
        let names = known.filter { traits.contains($0.0) }.map(\.1)
        return names.isEmpty ? nil : names
    }
}

// MARK: - AppKit (macOS)

#elseif canImport(AppKit)
extension DebugScreenCapture {
    @MainActor
    static func visibleWindows() -> [NSWindow] {
        NSApplication.shared.windows.filter { $0.isVisible && $0.frame.width > 0 }
    }

    @MainActor static func isKey(_ window: NSWindow) -> Bool { window.isKeyWindow }
    @MainActor static func bounds(of window: NSWindow) -> CGRect { window.contentView?.bounds ?? .zero }

    @MainActor
    static func pngData(of window: NSWindow, scale: Double, background: String) -> Data? {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    @MainActor
    static func describe(_ object: Any, depth: Int, budget: inout Int) -> [Element] {
        guard depth < maxDepth, budget > 0 else { return [] }
        let node: Any = (object as? NSWindow)?.contentView ?? object
        guard let element = node as? NSAccessibilityProtocol else { return [] }
        let isElement = element.isAccessibilityElement()
        var children: [Element] = []
        var sources: [Any] = element.accessibilityChildren() ?? []
        if sources.isEmpty, let view = node as? NSView { sources = view.subviews }
        for child in sources { children += describe(child, depth: depth + 1, budget: &budget) }
        guard isElement else { return children }
        budget -= 1
        return [Element(kind: element.accessibilityRole()?.rawValue ?? String(describing: type(of: node)),
                        label: text(element.accessibilityLabel()), value: text(element.accessibilityValue().map { "\($0)" }),
                        hint: text(element.accessibilityHelp()), traits: nil,
                        frame: frame(element.accessibilityFrame()), children: children.isEmpty ? nil : children)]
    }
}
#endif
