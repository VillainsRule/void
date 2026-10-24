import SwiftUI

struct BindView: View {
    @Environment(ServiceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: EditTarget
    @State private var hostname = ""
    @State private var port = ""
    @State private var saving = false

    private var secure: Bool { Service(name: "", command: "", repo: "", hostname: hostname.lowercased()).wantsSSL }

    private var service: Service? { store.services.first { $0.id == target.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bind \(service?.name ?? "service") to hostname").font(.headline)
            VStack(spacing: 8) {
                TextField("Hostname (e.g. myapp.test)", text: $hostname)
                TextField("Port", text: $port)
            }
            .textFieldStyle(.roundedBorder)
            Text(secure ? "Serves http:// and https:// (local trusted certificate). Needs your password." : "Serves http://\(hostname.isEmpty ? "hostname" : hostname) on port 80. Needs your password.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = store.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(4)
            }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                if service?.hostname != nil {
                    Button("Unbind") {
                        guard let service else { return }
                        saving = true
                        Task {
                            let ok = await store.unbind(service)
                            saving = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(saving)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Bind") {
                    guard let service else { return }
                    saving = true
                    Task {
                        let ok = await store.bind(service, hostname: hostname, port: Int(port) ?? 0)
                        saving = false
                        if ok { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || hostname.isEmpty || port.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(WindowFocus())
        .onAppear {
            store.error = nil
            hostname = service?.hostname ?? ""
            if let bound = service?.hostPort { port = String(bound) }
            else if let detected = store.ports[target.id ?? UUID()]?.first { port = String(detected.port) }
        }
    }
}
