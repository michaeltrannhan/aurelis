import CoreAudio
import Foundation

enum CoreAudioDiscoveryError: LocalizedError {
    case propertyReadFailed(objectID: AudioObjectID, selector: AudioObjectPropertySelector, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case let .propertyReadFailed(objectID, selector, status):
            return "CoreAudio property \(Self.fourCC(selector)) failed for object \(objectID) with status \(status)"
        }
    }

    private static func fourCC(_ selector: AudioObjectPropertySelector) -> String {
        let bytes = [
            UInt8((selector >> 24) & 0xff),
            UInt8((selector >> 16) & 0xff),
            UInt8((selector >> 8) & 0xff),
            UInt8(selector & 0xff)
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? "\(selector)"
    }
}

enum CoreAudioPropertyReader {
    static func scalar<T: FixedWidthInteger>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> T {
        var address = propertyAddress(selector: selector, scope: scope, element: element)
        var value = T.zero
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw CoreAudioDiscoveryError.propertyReadFailed(objectID: objectID, selector: selector, status: status)
        }
        return value
    }

    static func bool(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> Bool {
        let value: UInt32 = try scalar(objectID: objectID, selector: selector, scope: scope, element: element)
        return value != 0
    }

    static func double(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> Double {
        var address = propertyAddress(selector: selector, scope: scope, element: element)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw CoreAudioDiscoveryError.propertyReadFailed(objectID: objectID, selector: selector, status: status)
        }
        return value
    }

    static func array<T: FixedWidthInteger>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> [T] {
        var address = propertyAddress(selector: selector, scope: scope, element: element)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr else {
            throw CoreAudioDiscoveryError.propertyReadFailed(objectID: objectID, selector: selector, status: status)
        }
        guard size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<T>.stride
        var values = Array(repeating: T.zero, count: count)
        status = values.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else {
            throw CoreAudioDiscoveryError.propertyReadFailed(objectID: objectID, selector: selector, status: status)
        }
        return values
    }

    static func string(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> String {
        var address = propertyAddress(selector: selector, scope: scope, element: element)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            throw CoreAudioDiscoveryError.propertyReadFailed(objectID: objectID, selector: selector, status: status)
        }
        return value?.takeRetainedValue() as String? ?? ""
    }

    /// Reads a Core Audio property whose value is a retained `CFArray` of
    /// `CFString` values, such as an aggregate device's ordered subdevice UIDs.
    static func stringArray(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> [String] {
        var address = propertyAddress(selector: selector, scope: scope, element: element)
        var value: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            throw CoreAudioDiscoveryError.propertyReadFailed(objectID: objectID, selector: selector, status: status)
        }
        guard let value else { return [] }
        return (value.takeRetainedValue() as NSArray).compactMap { $0 as? String }
    }

    static func hasProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> Bool {
        var address = propertyAddress(selector: selector, scope: scope, element: element)
        return AudioObjectHasProperty(objectID, &address)
    }

    private static func propertyAddress(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }
}
