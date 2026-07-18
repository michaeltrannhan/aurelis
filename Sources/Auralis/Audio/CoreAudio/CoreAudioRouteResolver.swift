import Foundation

/// Result of resolving a `DeviceRoute` against the currently available output
/// devices. A fallback result means every selected device is gone and audio
/// should use the default output without discarding the stored preference.
enum CoreAudioResolvedRoute: Equatable {
    case resolved(String)
    case resolvedMany([String])
    case fallback(String)
    case fallbackMany([String])
    case unavailable

    var outputDeviceUIDs: [String] {
        switch self {
        case let .resolved(uid), let .fallback(uid):
            return [uid]
        case let .resolvedMany(uids), let .fallbackMany(uids):
            return uids
        case .unavailable:
            return []
        }
    }

    var outputDeviceUID: String? {
        outputDeviceUIDs.first
    }
}

/// Pure resolver mapping route intent to an ordered output-device UID list.
/// Kept free of CoreAudio calls so route logic is fully unit-testable.
struct CoreAudioRouteResolver {
    var availableOutputUIDs: Set<String>
    var defaultOutputUIDs: [String]

    init(availableOutputUIDs: [String], defaultOutputUID: String?) {
        self.init(
            availableOutputUIDs: availableOutputUIDs,
            defaultOutputUIDs: defaultOutputUID.map { [$0] } ?? []
        )
    }

    init(availableOutputUIDs: [String], defaultOutputUIDs: [String]) {
        let available = Set(availableOutputUIDs.compactMap(Self.normalized))
        self.availableOutputUIDs = available
        var seen = Set<String>()
        self.defaultOutputUIDs = defaultOutputUIDs.compactMap { rawUID in
            guard let uid = Self.normalized(rawUID),
                  available.contains(uid),
                  seen.insert(uid).inserted else { return nil }
            return uid
        }
    }

    func resolve(_ route: DeviceRoute) -> CoreAudioResolvedRoute {
        switch route.normalized {
        case .followDefault:
            return defaultRoute(isFallback: false)
        case let .selectedDevice(uid):
            if availableOutputUIDs.contains(uid) {
                return .resolved(uid)
            }
            return defaultRoute(isFallback: true)
        case let .multiOutput(uids):
            let resolvedUIDs = uids.filter(availableOutputUIDs.contains)
            if !resolvedUIDs.isEmpty {
                return .resolvedMany(resolvedUIDs)
            }
            return defaultRoute(isFallback: true, forceMany: true)
        }
    }

    private func defaultRoute(isFallback: Bool, forceMany: Bool = false) -> CoreAudioResolvedRoute {
        switch defaultOutputUIDs.count {
        case 0:
            return .unavailable
        case 1:
            if forceMany { return .fallbackMany(defaultOutputUIDs) }
            return isFallback ? .fallback(defaultOutputUIDs[0]) : .resolved(defaultOutputUIDs[0])
        default:
            return isFallback ? .fallbackMany(defaultOutputUIDs) : .resolvedMany(defaultOutputUIDs)
        }
    }

    private static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
