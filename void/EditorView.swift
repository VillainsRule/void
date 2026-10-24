import SwiftUI

struct EditorView: View {
    @Environment(ServiceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: EditTarget
    @State private var name = ""
    @State private var command = ""
    @State private var repo = ""
    @State private var saving = false

    private var service: Service? { store.services.first { $0.id == target.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.id == nil ? "Add service" : "Edit service").font(.headline)
            VStack(spacing: 8) {
                TextField("Name", text: $name)
                TextField("Start command", text: $command)
                TextField("GitHub repository link", text: $repo)
            }
            .textFieldStyle(.roundedBorder)
            if let error = store.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(4)
            }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(target.id == nil ? "Add" : "Save") {
                    saving = true
                    Task {
                        let ok: Bool
                        if let service { ok = await store.update(service, name: name, command: command, repo: repo) }
                        else { ok = await store.add(name: name, command: command, repo: repo) }
                        saving = false
                        if ok { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || name.isEmpty || command.isEmpty || repo.isEmpty)
            }
        }
        .background(WindowFocus())
        .padding(16)
        .frame(width: 340)
        .onAppear {
            store.error = nil
            if let service {
                name = service.name
                command = service.command
                repo = service.repo
            }
        }
    }
}
