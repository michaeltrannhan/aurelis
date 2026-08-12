import Foundation

public enum AuralisDeepLink {
    public static let openMixer: URL = {
        guard let url = URL(string: "auralis://open") else {
            preconditionFailure("Invalid Auralis mixer deep link")
        }
        return url
    }()
}
