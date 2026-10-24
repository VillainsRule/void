import SwiftUI

struct MenuView: View {
    @Environment(ServiceStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("void").font(.headline)
                Spacer()
                Button { openWindow(id: "editor", value: EditTarget()); NSApp.activate() } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }

            if let error = store.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(4)
            }

            if store.services.isEmpty {
                Text("No services yet").foregroundStyle(.secondary)
            }

            ForEach(store.services) { service in
                let isRunning = store.running.contains(service.id)
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(service.name).font(.body)
                        Text(isRunning ? "running" : "stopped")
                            .font(.caption)
                            .foregroundStyle(isRunning ? .green : .secondary)
                    }
                    if store.updates.contains(service.id) {
                        Button { store.pull(service) } label: {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Update available")
                    }
                    if store.busy.contains(service.id) { ProgressView().controlSize(.small) }
                    Spacer()
                    if isRunning {
                        let ports = store.ports[service.id] ?? []
                        if ports.count == 1 {
                            Button { store.open(port: ports[0]) } label: {
                                Image(systemName: "globe")
                                    .frame(width: 18, height: 18)
                            }
                            .buttonStyle(.borderless)
                            .help(ports[0].label)
                        } else if ports.count > 1 {
                            Menu {
                                ForEach(ports, id: \.self) { port in
                                    Button(port.label) { store.open(port: port) }
                                }
                            } label: {
                                Image(systemName: "globe")
                                    .frame(width: 18, height: 18)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                        Button { openWindow(id: "logs", value: service.id); NSApp.activate() } label: {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.borderless)
                        .help("Logs")
                    }
                    Button { isRunning ? store.stop(service) : store.start(service) } label: {
                        Image(systemName: isRunning ? "pause.fill" : "play.fill")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderless)
                }
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Edit…") { openWindow(id: "editor", value: EditTarget(id: service.id)); NSApp.activate() }
                    Button("Bind to hostname…") { openWindow(id: "bind", value: EditTarget(id: service.id)); NSApp.activate() }
                    Divider()
                    Menu("Recent logs") {
                        let recent = store.recentLogs(service)
                        if recent.isEmpty { Text("No logs yet") }
                        ForEach(recent, id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")) { store.open(log: url) }
                        }
                    }
                    Divider()
                    Button("Open in Finder") { store.openInFinder(service) }
                    Button("Open in Terminal") { store.openInTerminal(service) }
                    Button("Force Pull Latest") { store.pull(service) }
                    Divider()
                    Button("Remove") { store.remove(service) }
                }
            }
        }
        .padding(12)
        .frame(width: 240)
    }
}
