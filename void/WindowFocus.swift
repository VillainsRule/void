import SwiftUI
import AppKit

struct WindowFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            NSApp.activate()
            view.window?.makeKeyAndOrderFront(nil)
            view.window?.orderFrontRegardless()
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
