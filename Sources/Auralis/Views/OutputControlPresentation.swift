struct OutputControlPresentation: Equatable {
    let showsVolume: Bool
    let enablesVolume: Bool
    let showsMute: Bool
    let enablesMute: Bool

    init(capabilities: OutputControlCapabilities) {
        showsVolume = capabilities.canReadVolume
        enablesVolume = capabilities.canReadVolume && capabilities.canSetVolume
        showsMute = capabilities.canReadMute
        enablesMute = capabilities.canReadMute && capabilities.canSetMute
    }

    var hasAnyReadableControl: Bool { showsVolume || showsMute }
}
