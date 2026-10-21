import AppKit
import SwiftUI

/// Settings → Appearance: how the window is drawn and how panes are laid out.
/// Changes apply live to every window; panes keep running.
///
/// Each value can be forced for one launch with an environment variable of the same
/// name (RAPTOR_INTERFACE_STYLE=solid), which scripted screenshots use.
final class RaptorAppearance: ObservableObject {
    static let shared = RaptorAppearance()

    enum Style: String, CaseIterable, Identifiable {
        /// Opaque chrome in the theme's tint.
        case solid
        /// The desktop blurred behind the window, tinted by the theme.
        case blended
        /// Liquid glass, macOS 26 and later.
        case glass

        var id: Self { self }

        var name: String {
            switch self {
            case .solid: "Solid"
            case .blended: "Blended"
            case .glass: "Glass"
            }
        }
    }

    enum Density: String, CaseIterable, Identifiable {
        /// Each pane is a rounded card with the chrome between them.
        case islands
        /// Panes tile edge to edge with 1 px dividers.
        case compact

        var id: Self { self }

        var name: String {
            switch self {
            case .islands: "Comfortable"
            case .compact: "Compact"
            }
        }
    }

    /// Which pane takes focus when the focused one closes.
    enum CloseFocus: String, CaseIterable, Identifiable {
        /// The pane bordering it, which takes its space.
        case adjacent
        /// The window's top-left pane.
        case first

        var id: Self { self }

        var name: String {
            switch self {
            case .adjacent: "Adjacent pane"
            case .first: "First pane"
            }
        }
    }

    /// Ghostty's window-padding-color: what fills the padding around the cells.
    enum PaddingColor: String, CaseIterable, Identifiable {
        case background
        case extend
        case extendAlways = "extend-always"

        var id: Self { self }

        var name: String {
            switch self {
            case .background: "Background"
            case .extend: "Extend"
            case .extendAlways: "Extend Always"
            }
        }
    }

    @Published var style: Style {
        didSet {
            save(style.rawValue, Keys.style)
            applyConfig()
        }
    }
    @Published var density: Density { didSet { save(density.rawValue, Keys.density) } }
    @Published var paneHeaders: Bool { didSet { save(paneHeaders, Keys.paneHeaders) } }
    /// Blended and Glass show the desktop through the panes as through the chrome.
    @Published var translucentPanes: Bool {
        didSet {
            save(translucentPanes, Keys.translucentPanes)
            applyConfig()
        }
    }
    /// Ghostty's font-thicken.
    @Published var fontSmoothing: Bool {
        didSet {
            save(fontSmoothing, Keys.fontSmoothing)
            applyConfig()
        }
    }
    /// The vertical sidebar of every session's tabs, in place of the tab strip.
    @Published var sidebar: Bool { didSet { save(sidebar, Keys.sidebar) } }
    /// The eye closed: the sidebar shows only tabs running a coding agent, each with
    /// its status line.
    @Published var activity: Bool { didSet { save(activity, Keys.activity) } }
    @Published var paddingColor: PaddingColor {
        didSet {
            save(paddingColor.rawValue, Keys.paddingColor)
            applyConfig()
        }
    }

    @Published var closeFocus: CloseFocus { didSet { save(closeFocus.rawValue, Keys.closeFocus) } }

    private enum Keys {
        static let style = "RaptorInterfaceStyle"
        static let density = "RaptorPaneDensity"
        static let paneHeaders = "RaptorPaneHeaders"
        static let translucentPanes = "RaptorTranslucentPanes"
        static let fontSmoothing = "RaptorFontSmoothing"
        static let paddingColor = "RaptorPaddingColor"
        static let sidebar = "RaptorSidebar"
        static let activity = "RaptorActivity"
        static let closeFocus = "RaptorCloseFocus"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.defaults = defaults
        func value(_ key: String, _ env: String) -> String? {
            environment[env] ?? defaults.string(forKey: key)
        }
        style = value(Keys.style, "RAPTOR_INTERFACE_STYLE").flatMap(Style.init) ?? .blended
        density = value(Keys.density, "RAPTOR_PANE_DENSITY").flatMap(Density.init) ?? .islands
        paneHeaders = value(Keys.paneHeaders, "RAPTOR_PANE_HEADERS").map { $0 == "1" || $0 == "true" } ?? true
        translucentPanes = value(Keys.translucentPanes, "RAPTOR_TRANSLUCENT_PANES").map { $0 == "1" || $0 == "true" } ?? true
        fontSmoothing = defaults.bool(forKey: Keys.fontSmoothing)
        sidebar = value(Keys.sidebar, "RAPTOR_SIDEBAR").map { $0 == "1" || $0 == "true" } ?? true
        activity = value(Keys.activity, "RAPTOR_ACTIVITY").map { $0 == "1" || $0 == "true" } ?? false
        closeFocus = defaults.string(forKey: Keys.closeFocus).flatMap(CloseFocus.init) ?? .adjacent
        paddingColor = defaults.string(forKey: Keys.paddingColor).flatMap(PaddingColor.init) ?? .background
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    // MARK: Glass

    /// Glass needs macOS 26 and an SDK that has it.
    static var glassAvailable: Bool {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
#endif
        return false
    }

    /// The style in effect: Glass falls back to Blended where there is none.
    var effectiveStyle: Style {
        style == .glass && !Self.glassAvailable ? .blended : style
    }

    // MARK: Ghostty config

    /// Opacity of the theme background in translucent panes: the chrome's tint, so the
    /// desktop shows through the panes just as it does through the chrome around them.
    static let paneOpacity = RaptorWindowBackground.tint

    /// The panes' background-opacity: translucent in Blended and Glass unless turned off.
    var backgroundOpacity: Double {
        effectiveStyle != .solid && translucentPanes ? Self.paneOpacity : 1
    }

    /// Ghostty config that Raptor sets before the user's own, which can override it:
    /// an explicit background-opacity in the user's config wins in every style.
    var config: String {
        var lines = [
            // Rex doesn't dim unfocused panes; their headers darken instead.
            "unfocused-split-opacity = 1",
            "font-thicken = \(fontSmoothing)",
            "window-padding-color = \(paddingColor.rawValue)",
            // Ghostty's 2 pt default is lost under a card's rounded rim, leaving the
            // text against the frame; give it room as other terminals do.
            "window-padding-x = 8",
            "window-padding-y = 4",
            // Rex's pane chords. ⌘K is the Change Session menu item.
            "keybind = super+k=unbind",
            "keybind = super+enter=new_split:auto",
            "keybind = super+shift+arrow_down=new_split:down",
            "keybind = super+shift+arrow_right=new_split:right",
        ]
        lines.append("background-opacity = \(backgroundOpacity)")
        if effectiveStyle == .glass {
            lines.append("background-blur = macos-glass-regular")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Where `config` is written for Ghostty to load, nil if it couldn't be written.
    var configPath: String? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("Raptor", isDirectory: true)
        let file = dir.appendingPathComponent("appearance.ghostty")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try config.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return file.path
    }

    /// Reload Ghostty's config so the panes pick up the new style.
    private func applyConfig() {
        (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig()
    }
}
