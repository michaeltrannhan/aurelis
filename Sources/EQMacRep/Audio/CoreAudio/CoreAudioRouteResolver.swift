import Foundation

/// Result of resolving a `DeviceRoute` against the currently available output
/// devices. `.fallback` means the selected device is gone and audio should use
/// the default output without discarding the stored preference.
enum CoreAudioResolvedRoute: Equatable {
    case resolved(String)
    case fallback(String)
    case unavailable

    var outputDeviceUID: String? {
        switch self {
        case let .resolved(uid), let .fallback(uid):
            return uid
        case .unavailable:
            return nil
        }
    }
}

/// Pure resolver mapping route intent to an output device UID. Kept free of
/// CoreAudio calls so route logic is fully unit-testable.
struct CoreAudioRouteResolver {
    var availableOutputUIDs: Set<String>
    var defaultOutputUID: String?

    init(availableOutputUIDs: [String], defaultOutputUID: String?) {
        self.availableOutputUIDs = Set(availableOutputUIDs)
        self.defaultOutputUID = defaultOutputUID
    }

    func resolve(_ route: DeviceRoute) -> CoreAudioResolvedRoute {
        switch route {
        case .followDefault:
            guard let defaultOutputUID else { return .unavailable }
            return .resolved(defaultOutputUID)
        case let .selectedDevice(uid):
            if availableOutputUIDs.contains(uid) {
                return .resolved(uid)
            }
            guard let defaultOutputUID else { return .unavailable }
            return .fallback(defaultOutputUID)
        }
    }
}
