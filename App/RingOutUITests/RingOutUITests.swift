import XCTest

/// Drives first run on the simulated rig and captures each screen.
final class RingOutUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    @MainActor
    func testFirstRunToLiveOnSimulatedRig() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetForUITests"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft

        XCTAssertTrue(app.buttons["startSetup"].waitForExistence(timeout: 10))
        shot(app, "S1-welcome")
        app.buttons["startSetup"].tap()

        // Step 1: connect — choose the simulated rig.
        let sim = app.switches["simulatedToggle"]
        XCTAssertTrue(sim.waitForExistence(timeout: 5))
        sim.switches.firstMatch.exists ? sim.switches.firstMatch.tap() : sim.tap()
        shot(app, "S2-1-connect")
        app.buttons["wizardNext"].tap()

        // Step 2: wiring.
        XCTAssertTrue(app.buttons["topologyA"].waitForExistence(timeout: 5))
        shot(app, "S2-2-wiring")
        app.buttons["wizardNext"].tap()

        // Step 3: checks.
        sleep(2)
        shot(app, "S2-3-checks")
        app.buttons["wizardNext"].tap()

        // Step 4: calibrate.
        sleep(3)
        shot(app, "S2-4-calibrate")
        app.buttons["wizardNext"].tap()

        // Step 5: done.
        XCTAssertTrue(app.buttons["goLive"].waitForExistence(timeout: 5))
        shot(app, "S2-5-done")
        app.buttons["goLive"].tap()

        // Live.
        XCTAssertTrue(app.otherElements["strip1"].waitForExistence(timeout: 5) || app.buttons["bypass1"].waitForExistence(timeout: 5))
        sleep(3)
        shot(app, "S3-live")

        app.buttons["bypass1"].tap()
        sleep(1)
        shot(app, "S3-live-bypass")
        app.buttons["bypass1"].tap()

        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.buttons["settingsDone"].waitForExistence(timeout: 5))
        shot(app, "S6-settings")
        app.buttons["settingsDone"].tap()
    }
}
