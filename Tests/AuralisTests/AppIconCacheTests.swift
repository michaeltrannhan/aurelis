import AppKit
import XCTest
@testable import Auralis

@MainActor
final class AppIconCacheTests: XCTestCase {
    func testMissesAreNegativelyCachedUntilInvalidated() {
        var resolutionCount = 0
        let cache = AppIconCache { _ in
            resolutionCount += 1
            return nil
        }

        XCTAssertNil(cache.icon(forBundleID: "com.example.Missing"))
        XCTAssertNil(cache.icon(forBundleID: "com.example.Missing"))
        XCTAssertEqual(resolutionCount, 1)

        cache.invalidate(bundleID: "com.example.Missing")
        XCTAssertNil(cache.icon(forBundleID: "com.example.Missing"))
        XCTAssertEqual(resolutionCount, 2)
    }

    func testResolvedIconsAreCached() {
        var resolutionCount = 0
        let expected = NSImage(size: NSSize(width: 16, height: 16))
        let cache = AppIconCache { _ in
            resolutionCount += 1
            return expected
        }

        XCTAssertTrue(cache.icon(forBundleID: "com.example.App") === expected)
        XCTAssertTrue(cache.icon(forBundleID: "com.example.App") === expected)
        XCTAssertEqual(resolutionCount, 1)
    }

    func testCacheHasDeterministicLeastRecentlyUsedCapacity() {
        var resolutions: [String: Int] = [:]
        let cache = AppIconCache(capacity: 2) { bundleID in
            resolutions[bundleID, default: 0] += 1
            return NSImage(size: NSSize(width: 16, height: 16))
        }

        XCTAssertNotNil(cache.icon(forBundleID: "a"))
        XCTAssertNotNil(cache.icon(forBundleID: "b"))
        XCTAssertNotNil(cache.icon(forBundleID: "a"))
        XCTAssertNotNil(cache.icon(forBundleID: "c"))
        XCTAssertNotNil(cache.icon(forBundleID: "b"))

        XCTAssertEqual(resolutions["a"], 1)
        XCTAssertEqual(resolutions["b"], 2)
        XCTAssertEqual(resolutions["c"], 1)
    }
}
