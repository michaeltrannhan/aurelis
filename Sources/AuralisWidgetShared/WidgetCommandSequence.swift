import Darwin
import Foundation

/// POSIX-locked monotonic UInt64 sequence for widget command ordering.
public enum WidgetCommandSequence {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var nextValue: UInt64

        init() {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            let nanos = mach_absolute_time() * UInt64(info.numer) / UInt64(info.denom)
            nextValue = max(nanos, 1)
        }
    }

    private static let state = State()

    public static func next() -> UInt64 {
        state.lock.lock()
        defer { state.lock.unlock() }
        let value = state.nextValue
        state.nextValue &+= 1
        return value
    }

    /// Test seam — resets the allocator while preserving uniqueness within a process.
    public static func resetForTests(startingAt value: UInt64 = 1) {
        state.lock.lock()
        state.nextValue = max(value, 1)
        state.lock.unlock()
    }
}
