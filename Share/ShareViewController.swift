import SwiftUI

#if os(macOS)
    import AppKit

    /// The Share Sheet's entry point on the Mac.
    final class ShareViewController: NSViewController {
        override func loadView() {
            let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
            let host = NSHostingView(rootView: ShareView(items: items) { [weak self] added in self?.finish(added) })
            host.frame = NSRect(origin: .zero, size: NSSize(width: 420, height: 240))
            view = host
            preferredContentSize = host.frame.size
        }

        private func finish(_ added: Bool) {
            if added {
                extensionContext?.completeRequest(returningItems: nil)
            } else {
                extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            }
        }
    }
#else
    import UIKit

    /// The Share Sheet's entry point on iPhone and iPad.
    final class ShareViewController: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
            let host = UIHostingController(rootView: ShareView(items: items) { [weak self] added in self?.finish(added) })
            addChild(host)
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(host.view)
            host.didMove(toParent: self)
        }

        private func finish(_ added: Bool) {
            if added {
                extensionContext?.completeRequest(returningItems: nil)
            } else {
                extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            }
        }
    }
#endif
