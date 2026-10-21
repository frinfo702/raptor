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

    private static let newPaneDirectoriesKey = "RaptorNewPaneDirectories"

    /// The directory new panes and tabs start in on each machine, by its host ("" for
    /// this Mac). A machine without one starts them where the pane they come from is.
    static var newPaneDirectories: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: newPaneDirectoriesKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: newPaneDirectoriesKey) }
    }

    /// Where new panes and tabs start on the server's machine; nil starts them where the
    /// pane they come from is.
    static func newPaneDirectory(on server: RaptorClient) -> String? {
        newPaneDirectories[server.host ?? ""].map { $0.isEmpty ? "/" : $0 }
    }
}

struct RaptorSettingsView: View {
    @ObservedObject var appearance: RaptorAppearance
    @ObservedObject private var servers = RaptorClient.Servers.shared
    @State private var directories = RaptorSettings.newPaneDirectories

    var body: some View {
        Form {
            Section("New Panes and Tabs") {
                ForEach(servers.clients) { server in
                    let host = server.host ?? ""
                    Picker(server.name, selection: Binding(
                        get: { directories[host] != nil },
                        set: { directories[host] = $0 ? "/" : nil }
                    )) {
                        Text("Current directory").tag(false)
                        Text("Directory").tag(true)
                    }
                    if let dir = directories[host] {
                        TextField("Directory", text: Binding(
                            get: { dir },
                            set: { directories[host] = $0 }
                        ), prompt: Text("/"))
                    }
                }
            }
            .onChange(of: directories) { RaptorSettings.newPaneDirectories = $0 }
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
            Section("Panes") {
                Picker("Focus after closing a pane", selection: $appearance.closeFocus) {
                    ForEach(RaptorAppearance.CloseFocus.allCases) { Text($0.name).tag($0) }
                }
            }
            Section {
                Button("Open Config File…") {
                    (NSApp.delegate as? AppDelegate)?.ghostty.openConfig()
                }
                .raptorHover(tint: false)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}
