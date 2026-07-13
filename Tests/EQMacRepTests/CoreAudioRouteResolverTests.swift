import XCTest
@testable import EQMacRep

final class CoreAudioRouteResolverTests: XCTestCase {
    func testFollowDefaultResolvesToDefaultOutputUID() {
        let resolver = CoreAudioRouteResolver(
            availableOutputUIDs: ["built-in-output", "usb"],
            defaultOutputUID: "built-in-output"
        )

        let result = resolver.resolve(.followDefault)
        XCTAssertEqual(result, .resolved("built-in-output"))
        XCTAssertEqual(result.outputDeviceUIDs, ["built-in-output"])
    }

    func testFollowAggregateDefaultResolvesToAllPhysicalOutputsInOrder() {
        let resolver = CoreAudioRouteResolver(
            availableOutputUIDs: ["built-in", "usb", "hdmi"],
            defaultOutputUIDs: [" hdmi ", "missing", "usb", "hdmi", ""]
        )

        XCTAssertEqual(
            resolver.resolve(.followDefault),
            .resolvedMany(["hdmi", "usb"])
        )
        XCTAssertEqual(
            resolver.resolve(.selectedDevice("missing")),
            .fallbackMany(["hdmi", "usb"])
        )
    }

    func testSelectedDeviceResolvesWhenAvailable() {
        let resolver = CoreAudioRouteResolver(
            availableOutputUIDs: ["built-in-output", "usb"],
            defaultOutputUID: "built-in-output"
        )

        let result = resolver.resolve(.selectedDevice("usb"))
        XCTAssertEqual(result, .resolved("usb"))
        XCTAssertEqual(result.outputDeviceUIDs, ["usb"])
    }

    func testMissingSelectedDeviceFallsBackToDefault() {
        let resolver = CoreAudioRouteResolver(
            availableOutputUIDs: ["built-in-output"],
            defaultOutputUID: "built-in-output"
        )

        let result = resolver.resolve(.selectedDevice("missing"))
        XCTAssertEqual(result, .fallback("built-in-output"))
        XCTAssertEqual(result.outputDeviceUIDs, ["built-in-output"])
    }

    func testFollowDefaultUnavailableWhenNoDefault() {
        let resolver = CoreAudioRouteResolver(availableOutputUIDs: [], defaultOutputUID: nil)

        XCTAssertEqual(resolver.resolve(.followDefault), .unavailable)
        XCTAssertNil(resolver.resolve(.followDefault).outputDeviceUID)
        XCTAssertEqual(resolver.resolve(.followDefault).outputDeviceUIDs, [])
    }

    func testResolvedRouteExposesOutputUIDs() {
        XCTAssertEqual(CoreAudioResolvedRoute.resolved("a").outputDeviceUID, "a")
        XCTAssertEqual(CoreAudioResolvedRoute.fallback("b").outputDeviceUID, "b")
        XCTAssertNil(CoreAudioResolvedRoute.unavailable.outputDeviceUID)
        XCTAssertEqual(CoreAudioResolvedRoute.resolved("a").outputDeviceUIDs, ["a"])
        XCTAssertEqual(CoreAudioResolvedRoute.fallback("b").outputDeviceUIDs, ["b"])
        XCTAssertEqual(CoreAudioResolvedRoute.resolvedMany(["a", "b"]).outputDeviceUIDs, ["a", "b"])
        XCTAssertEqual(CoreAudioResolvedRoute.fallbackMany(["c"]).outputDeviceUIDs, ["c"])
    }

    func testMultiOutputResolvesOnlyAvailableDevicesInStoredOrder() {
        let resolver = CoreAudioRouteResolver(
            availableOutputUIDs: ["built-in", "usb", "hdmi"],
            defaultOutputUID: "built-in"
        )

        XCTAssertEqual(
            resolver.resolve(.multiOutput(["hdmi", "missing", "usb", "hdmi"])),
            .resolvedMany(["hdmi", "usb"])
        )
    }

    func testMultiOutputFallsBackWhenAllSelectedDevicesAreMissing() {
        let resolver = CoreAudioRouteResolver(
            availableOutputUIDs: ["built-in"],
            defaultOutputUID: "built-in"
        )

        XCTAssertEqual(
            resolver.resolve(.multiOutput(["missing"])),
            .fallbackMany(["built-in"])
        )
    }

    func testMultiOutputIsUnavailableWhenAllSelectedDevicesAndDefaultAreMissing() {
        let resolver = CoreAudioRouteResolver(availableOutputUIDs: [], defaultOutputUID: nil)

        XCTAssertEqual(resolver.resolve(.multiOutput(["missing"])), .unavailable)
    }
}
