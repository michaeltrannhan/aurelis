import Foundation

enum AudioBackendFactory {
    static func makeBackend(mode: BackendMode) -> any AudioBackend {
        switch mode {
        case .mock:
            return MockAudioBackend()
        case .coreAudioDiscovery:
            return CoreAudioDiscoveryBackend(runStartupRecovery: true)
        }
    }
}
