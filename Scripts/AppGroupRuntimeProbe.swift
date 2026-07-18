import Foundation

enum ProbeFailure: Error, CustomStringConvertible {
    case usage
    case unavailable(String)
    case mismatch(expected: String, actual: String)

    var description: String {
        switch self {
        case .usage:
            "usage: AppGroupRuntimeProbe <group-id> <write|read> <marker-name> <token>"
        case let .unavailable(groupID):
            "signed process could not resolve app group \(groupID)"
        case let .mismatch(expected, actual):
            "shared marker mismatch: expected \(expected), found \(actual)"
        }
    }
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count == 5 else { throw ProbeFailure.usage }
    let groupID = arguments[1]
    let operation = arguments[2]
    let markerName = arguments[3]
    let token = arguments[4]
    guard let containerURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: groupID
    ) else {
        throw ProbeFailure.unavailable(groupID)
    }
    let markerURL = containerURL.appendingPathComponent(markerName, isDirectory: false)

    switch operation {
    case "write":
        try Data(token.utf8).write(to: markerURL, options: .atomic)
    case "read":
        let actual = String(decoding: try Data(contentsOf: markerURL), as: UTF8.self)
        guard actual == token else {
            throw ProbeFailure.mismatch(expected: token, actual: actual)
        }
        try FileManager.default.removeItem(at: markerURL)
    default:
        throw ProbeFailure.usage
    }

    print(containerURL.standardizedFileURL.path)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
