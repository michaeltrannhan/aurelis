import AppKit
import SwiftUI

enum AppWindowID: String, Sendable {
    case main = "main"

    var nsIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("com.michaeltrannhan.EQMacRep.window.\(rawValue)")
    }
}

enum AppURLRoute: Equatable, Sendable {
    case openMainWindow

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "eqmacrep",
              url.host?.lowercased() == "open",
              url.path.isEmpty,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil else { return nil }
        self = .openMainWindow
    }
}

/// Routes AppKit-originated commands by an identifier installed on the SwiftUI
/// window, never by localized title text.
@MainActor
final class AppWindowRouter {
    @discardableResult
    func showMainWindow() -> Bool {
        guard let window = NSApp.windows.first(where: {
            $0.identifier == AppWindowID.main.nsIdentifier
        }) else { return false }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }
}

@MainActor
protocol AppWindowRouting: AnyObject {
    @discardableResult func showMainWindow() -> Bool
}

extension AppWindowRouter: AppWindowRouting {}

/// Installs the stable AppKit identifier once SwiftUI attaches this marker to
/// its containing window.
struct WindowIdentityInstaller: NSViewRepresentable {
    let identifier: AppWindowID

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            view?.window?.identifier = identifier.nsIdentifier
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if view.window?.identifier != identifier.nsIdentifier {
            DispatchQueue.main.async { [weak view] in
                view?.window?.identifier = identifier.nsIdentifier
            }
        }
    }
}
