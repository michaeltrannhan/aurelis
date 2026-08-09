import AppKit
import SwiftUI

enum AuralisColor {
    static let workbench = Color(red: 0xF4 / 255, green: 0xF7 / 255, blue: 0xFB / 255)
    static let nightDeck = Color(red: 0x07 / 255, green: 0x14 / 255, blue: 0x26 / 255)
    static let graphite = Color(red: 0x17 / 255, green: 0x20 / 255, blue: 0x33 / 255)
    static let signalCyan = Color(red: 0x22 / 255, green: 0xD3 / 255, blue: 0xEE / 255)
    static let harmonicViolet = Color(red: 0x8B / 255, green: 0x5C / 255, blue: 0xF6 / 255)
    static let peakRose = Color(red: 0xF4 / 255, green: 0x72 / 255, blue: 0xB6 / 255)

    static var canvas: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(calibratedRed: 0x07 / 255, green: 0x14 / 255, blue: 0x26 / 255, alpha: 1)
                : NSColor(calibratedRed: 0xF4 / 255, green: 0xF7 / 255, blue: 0xFB / 255, alpha: 1)
        })
    }

    static var panel: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(calibratedRed: 0x17 / 255, green: 0x20 / 255, blue: 0x33 / 255, alpha: 1)
                : NSColor.white
        })
    }
}

enum AuralisTypography {
    static func workspaceTitle(_ size: CGFloat = 22) -> Font {
        .custom("Avenir Next Condensed Demi Bold", size: size)
    }

    static func content(_ style: Font.TextStyle = .body) -> Font {
        .system(style, design: .default)
    }

    static func metric(_ size: CGFloat = 12) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }
}

enum AuralisSpacing {
    static let controlMinHit: CGFloat = 28
    static let inspectorBreakpoint: CGFloat = 960
}

enum MixerEmptyState: Equatable {
    case starting
    case refreshing
    case readyEmpty
    case permissionLimited
    case degraded
    case failed

    init(phase: MixerPhase) {
        switch phase {
        case .starting: self = .starting
        case .refreshing: self = .refreshing
        case .empty, .ready: self = .readyEmpty
        case .permissionLimited: self = .permissionLimited
        case .degraded: self = .degraded
        case .failed: self = .failed
        }
    }

    var title: String {
        switch self {
        case .starting: "Starting mixer"
        case .refreshing: "Refreshing apps"
        case .readyEmpty: "No audible apps yet"
        case .permissionLimited: "Audio permission required"
        case .degraded: "Mixer is degraded"
        case .failed: "Couldn’t load apps"
        }
    }

    var message: String {
        switch self {
        case .starting: "Auralis is preparing discovery."
        case .refreshing: "Looking for apps that are playing audio."
        case .readyEmpty: "Play something, then refresh — or show inactive apps."
        case .permissionLimited: "Grant Screen & System Audio Recording to control per-app audio."
        case .degraded: "Some controls need attention. Refresh or review issues above."
        case .failed: "Audio discovery failed. Refresh to try again."
        }
    }
}
