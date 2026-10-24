import SwiftUI

struct LogView: View {
    @Environment(ServiceStore.self) private var store
    let id: UUID

    var body: some View {
        let text = store.logs[id] ?? ""
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "No output yet" : text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                Color.clear.frame(height: 1).id("end")
            }
            .onChange(of: text) { proxy.scrollTo("end") }
        }
        .background(WindowFocus())
        .navigationTitle(store.services.first { $0.id == id }?.name ?? "Logs")
    }
}
