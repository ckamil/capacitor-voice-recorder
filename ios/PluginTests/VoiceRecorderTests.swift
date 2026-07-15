import XCTest
@testable import Plugin

class VoiceRecorderTests: XCTestCase {

    func testEcho() {
        // This is an example of a functional test case for a plugin.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    // AMA-368: ObjCExceptionGuard is the load-bearing part of the Zoom screen-share crash fix.
    // AVAudioEngine.start()/installTap can raise an Objective-C NSException (NOT a Swift Error)
    // when the audio session is held by ReplayKit; Swift's do/catch cannot catch it. The guard
    // must convert that NSException into a NO + NSError so the caller can fall back gracefully.
    func testExceptionGuardCatchesNSException() {
        var error: NSError?
        let ok = ObjCExceptionGuard.tryBlock({
            NSException(name: .genericException, reason: "boom", userInfo: nil).raise()
        }, error: &error)

        XCTAssertFalse(ok, "guard must report failure when the block raises an NSException")
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.domain, "VoiceRecorderAudioEngine")
        XCTAssertEqual(error?.userInfo["exceptionName"] as? String, NSExceptionName.genericException.rawValue)
    }

    func testExceptionGuardPassesThroughNormalBlock() {
        var error: NSError?
        var ran = false
        let ok = ObjCExceptionGuard.tryBlock({ ran = true }, error: &error)

        XCTAssertTrue(ok, "guard must report success when the block completes normally")
        XCTAssertNil(error)
        XCTAssertTrue(ran, "guard must actually run the block")
    }
}
