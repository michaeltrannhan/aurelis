import XCTest
@testable import EQMacRep

final class CoreAudioRouteResolverTests: XCTestCase {
    func testFollowDefaultResolvesToDefaultOutputUID() {
        let resolver = CoreAudioRouteResolver(
            availableOutputUIDs: ["built-in-output", "usb"],
            defaultOutputUID: "built-in-output"
        )

        XCTAssertEqual(resolver.resolve(.followDefault), .resolved("built-in-output"))
    }

    func testSelectedDeviceResolvesWhenAvailable() {
        let resolver = CoreAudioRouteResolver(
            availableOutputUIDs: ["built-in-output", "usb"],
            defaultOutputUID: "built-in-output"
        )

        XCTAssertEqual(resolver.resolve(.selectedDevice("usb")), .resolved("usb"))
    }

    func testMissingSelectedDeviceFallsBackToDefault() {
        let resolver = CoreAudioRouteResolver(
            availableOutputUIDs: ["built-in-output"],
            defaultOutputUID: "built-in-output"
        )

        XCTAssertEqual(resolver.resolve(.selectedDevice("missing")), .fallback("built-in-output"))
    }

    func testFollowDefaultUnavailableWhenNoDefault() {
        let resolver = CoreAudioRouteResolver(availableOutputUIDs: [], defaultOutputUID: nil)

        XCTAssertEqual(resolver.resolve(.followDefault), .unavailable)
        XCTAssertNil(resolver.resolve(.followDefault).outputDeviceUID)
    }

    func testResolvedRouteExposesOutputUID() {
        XCTAssertEqual(CoreAudioResolvedRoute.resolved("a").outputDeviceUID, "a")
        XCTAssertEqual(CoreAudioResolvedRoute.fallback("b").outputDeviceUID, "b")
        XCTAssertNil(CoreAudioResolvedRoute.unavailable.outputDeviceUID)
    }
}
