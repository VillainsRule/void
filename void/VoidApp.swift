import SwiftUI

@main struct VoidApp: App {
    @State private var store = ServiceStore()

    var body: some Scene {
        MenuBarExtra("void", systemImage: "wrench.and.screwdriver") {
            MenuView()
                .environment(store)
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Logs", id: "logs", for: UUID.self) { $id in
            if let id { LogView(id: id).environment(store) }
        }
        .defaultSize(width: 640, height: 400)

        WindowGroup("Service", id: "editor", for: EditTarget.self) { $target in
            EditorView(target: target ?? EditTarget()).environment(store)
        }
        .windowResizability(.contentSize)

        WindowGroup("Bind hostname", id: "bind", for: EditTarget.self) { $target in
            if let target { BindView(target: target).environment(store) }
        }
        .windowResizability(.contentSize)
    }
}
