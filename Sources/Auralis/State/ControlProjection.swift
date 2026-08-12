enum ControlProjection {
    static func committed(
        for target: ControlTarget,
        displayRows: [DisplayableAppRow],
        settings: PersistedSettings,
        devices: [AudioDeviceSnapshot],
        deviceVolumeStates: [String: OutputVolumeState]
    ) throws -> ControlProjectedState {
        switch target {
        case let .app(identity):
            if let row = displayRows.first(where: { $0.identity == identity }) {
                return appState(row.settings, displayName: row.displayName)
            }
            if let stored = settings.appSettings[identity] {
                return appState(stored, displayName: stored.displayName)
            }
            throw UserFacingFailure(
                title: "Unavailable",
                message: "The selected audio app is unavailable."
            )
        case let .outputDevice(deviceID):
            guard let device = devices.first(where: { $0.id == deviceID }) else {
                throw UserFacingFailure(
                    title: "Unavailable",
                    message: "The selected output device is unavailable."
                )
            }
            let state = deviceVolumeStates[deviceID]
            return ControlProjectedState(
                volume: state?.volume,
                isMuted: state?.isMuted,
                eq: settings.deviceSettings[deviceID]?.eq
                    ?? EQCurve(range: settings.customization.eqGainRange),
                displayName: device.name
            )
        case .activeApps:
            return ControlProjectedState(displayName: "Active apps")
        }
    }

    static func applying(
        _ mutation: ControlMutation,
        to baseline: ControlProjectedState,
        target: ControlTarget
    ) throws -> ControlProjectedState {
        guard supports(mutation, for: target) else {
            throw UserFacingFailure(
                title: "Unsupported",
                message: "Try that control again from the mixer."
            )
        }

        var next = baseline
        switch mutation {
        case let .adjustVolume(delta):
            next.volume = min(max((next.volume ?? 1) + delta, 0), 1)
            if case .app = target {
                if (next.volume ?? 0) > 0.001, next.isMuted == true, delta > 0 {
                    next.isMuted = false
                }
                if (next.volume ?? 0) <= 0.001 {
                    next.isMuted = true
                }
            }
        case let .setVolume(volume):
            next.volume = min(max(volume, 0), 1)
        case .toggleMute:
            next.isMuted = !(next.isMuted ?? false)
        case let .setMuted(muted):
            next.isMuted = muted
        case let .setBoost(boost):
            next.boost = boost
        case let .setEQ(eq):
            next.eq = eq
        case let .setEQBand(band, gain):
            var eq = next.eq ?? EQCurve()
            eq.setGain(gain, at: band)
            next.eq = eq
        case let .setRoute(route):
            next.route = route.normalized
        }
        return next
    }

    private static func appState(
        _ settings: AppAudioSettings,
        displayName: String
    ) -> ControlProjectedState {
        ControlProjectedState(
            volume: settings.volume,
            isMuted: settings.isMuted,
            boost: settings.boost,
            eq: settings.eq,
            route: settings.route,
            displayName: displayName
        )
    }

    private static func supports(_ mutation: ControlMutation, for target: ControlTarget) -> Bool {
        switch mutation {
        case .adjustVolume, .toggleMute, .setEQ, .setEQBand:
            switch target {
            case .app, .outputDevice: true
            case .activeApps: false
            }
        case .setVolume, .setMuted:
            true
        case .setBoost, .setRoute:
            if case .app = target { true } else { false }
        }
    }
}
