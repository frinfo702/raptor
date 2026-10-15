import AppKit
import SwiftUI

/// The Settings window. Appearance changes apply to open windows as they're made.
enum RaptorSettings {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: RaptorSettingsView(appearance: .shared)))
            w.title = "Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

struct RaptorSettingsView: View {
    @ObservedObject var appearance: RaptorAppearance

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Interface style", selection: $appearance.style) {
                    ForEach(RaptorAppearance.Style.allCases.filter { $0 != .glass || RaptorAppearance.glassAvailable }) {
                        Text($0.name).tag($0)
                    }
                }
                Picker("Pane density", selection: $appearance.density) {
                    ForEach(RaptorAppearance.Density.allCases) { Text($0.name).tag($0) }
                }
                Toggle("Pane headers", isOn: $appearance.paneHeaders)
                Toggle(isOn: $appearance.translucentPanes) {
                    Text("Translucent panes")
                    Text("Blended and Glass show the desktop through panes as through the window around them. A background-opacity in your config file takes precedence.")
                }
                .disabled(appearance.effectiveStyle == .solid)
            }
            Section {
                Button("Open Config File…") {
                    (NSApp.delegate as? AppDelegate)?.ghostty.openConfig()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}
