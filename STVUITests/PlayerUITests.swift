import XCTest

/// 1.4b10 player v3 (design v3): 7 bottom icons + glass popovers; 1.4b9: portrait by default (even for landscape video), landscape only via rotation or the 横屏 button;
/// new progress bar (drag to seek). Plays a local test-pattern MP4 (ffmpeg testsrc) — no network, no real content.
final class PlayerUITests: XCTestCase {
    var app: XCUIApplication!
    static let video = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("STVTests/Fixtures/player_landscape.mp4").path

    func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    var isLandscape: Bool { let f = app.windows.firstMatch.frame; return f.width > f.height }
    func waitOrientation(landscape: Bool, timeout: TimeInterval = 6) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if isLandscape == landscape { return true }; Thread.sleep(forTimeInterval: 0.25) }
        return isLandscape == landscape
    }
    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["STV_SHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }
    /// Chrome auto-hides after 3.5 s; a single tap while hidden only shows it.
    func showChrome(_ id: String) {
        if el(id).exists && el(id).isHittable { return }
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22)).tap()   // above the center ⟲10/▶/⟳10
        XCTAssertTrue(el(id).waitForExistence(timeout: 4), "chrome did not show \(id)")
    }
    func seconds(_ s: String) -> Int {
        let first = s.components(separatedBy: " / ").first ?? ""
        return first.split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
    }
    func launch(_ extra: [String: String] = [:]) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchEnvironment["STV_ROUTE"] = "fxplay:" + Self.video
        for (k, v) in extra { app.launchEnvironment[k] = v }
        app.launch()
    }

    func testPortraitDefaultRotationAndFullscreenButton() {
        launch()
        XCTAssertTrue(el("player.progress").waitForExistence(timeout: 20), "player did not become ready")
        XCTAssertTrue(waitOrientation(landscape: false), "landscape video must open in portrait")
        shot("pl_01_portrait_landscape_video")

        // 横屏 button → landscape; 退出横屏 → portrait.
        showChrome("player.fullscreen"); el("player.fullscreen").tap()
        XCTAssertTrue(waitOrientation(landscape: true), "横屏 button did not rotate")
        showChrome("player.exitFullscreen")
        el("player.exitFullscreen").tap()
        XCTAssertTrue(waitOrientation(landscape: false), "退出横屏 did not rotate back")

        // Rotating the device follows (rotation lock off), and rotating back exits.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitOrientation(landscape: true), "device rotation not followed")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitOrientation(landscape: false), "rotating back did not exit landscape")
    }

    /// An audio interruption that never sends `.ended` (another app took audio / PiP interrupted): one tap on ▶ must resume.
    func testPlayAfterInterruptionWithoutEnd() {
        launch(["STV_FAKE_INTERRUPT": "3"])
        let bar = el("player.progress")
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "player did not become ready")
        Thread.sleep(forTimeInterval: 5)
        showChrome("player.progress")
        let t1 = seconds(el("player.progress").value as? String ?? "")
        Thread.sleep(forTimeInterval: 2)
        showChrome("player.progress")
        XCTAssertEqual(seconds(el("player.progress").value as? String ?? ""), t1, "fake interruption did not stop playback")
        showChrome("player.playPause"); el("player.playPause").tap()
        Thread.sleep(forTimeInterval: 3)
        showChrome("player.progress")
        let t2 = seconds(el("player.progress").value as? String ?? "")
        XCTAssertGreaterThanOrEqual(t2 - t1, 2, "▶ after an interruption did not resume: \(t1)s → \(t2)s")
    }

    /// Side taps: double tap = 10 s, a third tap in the streak keeps going (20 s total), bubble on that side.
    /// The fixture is 60 s long, so seek toward whichever end has room; tap below the centre controls.
    func testDoubleTapSeekAccumulates() {
        launch()
        let bar = el("player.progress")
        XCTAssertTrue(bar.waitForExistence(timeout: 20))
        showChrome("player.progress")
        let before = seconds(bar.value as? String ?? "")
        let forward = before < 30
        let side = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.88 : 0.12, dy: 0.64))
        side.doubleTap(); side.tap()
        XCTAssertTrue(el("player.seekRun").waitForExistence(timeout: 1), "seek bubble did not show")
        shot("pl_06_double_tap_seek")
        showChrome("player.progress")
        let after = seconds(el("player.progress").value as? String ?? "")
        // Two seeks in one streak: the playhead moves ≥ 18 s in that direction.
        let moved = forward ? after - before : before - after
        XCTAssertGreaterThanOrEqual(moved, 18, "double-tap seek did not accumulate: \(before)s → \(after)s")
    }

    func testProgressBarDragSeeks() {
        launch()
        let bar = el("player.progress")
        XCTAssertTrue(bar.waitForExistence(timeout: 20))
        showChrome("player.progress")
        let before = seconds(bar.value as? String ?? "")
        let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        let end = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        showChrome("player.progress")
        let after = seconds(el("player.progress").value as? String ?? "")
        XCTAssertGreaterThanOrEqual(after, 30, "seek by drag failed: \(before)s → \(after)s")
        XCTAssertFalse(el("player.prebuffer").exists, "separate 已缓存 line should be gone")
        // Tap on the bar (no drag) also seeks.
        el("player.progress").coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        showChrome("player.progress")
        XCTAssertLessThan(seconds(el("player.progress").value as? String ?? ""), 25, "tap-to-seek failed")
    }

    /// Pinch out on the video → 铺满全屏, pinch in → 完整自适应.
    func testPinchTogglesFill() {
        launch(["STV_FILL": "0"])
        XCTAssertTrue(el("player.progress").waitForExistence(timeout: 20))
        let video = el("player.video")
        XCTAssertEqual(video.value as? String, "fit")
        app.windows.firstMatch.pinch(withScale: 2.2, velocity: 3)
        XCTAssertTrue(waitValue(video, "fill"), "pinch out did not fill: \(video.value ?? "-")")
        shot("pl_07_pinch_fill")
        app.windows.firstMatch.pinch(withScale: 0.45, velocity: -3)
        XCTAssertTrue(waitValue(video, "fit"), "pinch in did not fit: \(video.value ?? "-")")
    }

    private func waitValue(_ e: XCUIElement, _ v: String, timeout: TimeInterval = 3) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if e.value as? String == v { return true }; Thread.sleep(forTimeInterval: 0.2) }
        return e.value as? String == v
    }

    func testScrubbingLookScreenshot() {
        launch(["STV_SCRUB_DEMO": "0.62"])
        XCTAssertTrue(el("player.progress.bubble").waitForExistence(timeout: 20), "drag bubble not shown")
        shot("pl_02_scrubbing")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitOrientation(landscape: true))
        // Landscape screenshots are taken with `simctl io screenshot` while STV_HOLD keeps this state
        // (XCUITest captures mid-rotation frames).
        if let hold = Double(ProcessInfo.processInfo.environment["STV_HOLD"] ?? "") { print("HOLDING-LANDSCAPE"); Thread.sleep(forTimeInterval: hold) }
        XCUIDevice.shared.orientation = .portrait
    }

    /// Opt-in (`STV_LIVE_HG=1`, needs the 红果 API): a real short drama in the new chrome, portrait + scrubbing.
    func testLiveHongguoShortDrama() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STV_LIVE_HG"] == "1")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchEnvironment["STV_HERO_STILL"] = "1"
        if let f = ProcessInfo.processInfo.environment["STV_SCRUB_DEMO"] { app.launchEnvironment["STV_SCRUB_DEMO"] = f }
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["home.card"].firstMatch.waitForExistence(timeout: 25))
        el("home.page.红果").swipeUp()
        Thread.sleep(forTimeInterval: 1)
        let card = app.descendants(matching: .any).matching(identifier: "home.card").allElementsBoundByIndex
            .first { $0.frame.minY > 120 && $0.frame.maxY < app.frame.height - 110 }
        XCTAssertNotNil(card, "no card on screen")
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: card!.frame.midX, dy: card!.frame.midY)).tap()
        XCTAssertTrue(el("screen.detail").waitForExistence(timeout: 10), "detail did not open")
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '开始播放' OR label BEGINSWITH '继续'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15)); play.tap()
        XCTAssertTrue(el("player.progress").waitForExistence(timeout: 40), "short drama did not start")
        Thread.sleep(forTimeInterval: 4)
        showChrome("player.progress")
        shot(ProcessInfo.processInfo.environment["STV_SCRUB_DEMO"] == nil ? "pl_05_hongguo_portrait" : "pl_06_hongguo_scrubbing")
        if let hold = Double(ProcessInfo.processInfo.environment["STV_HOLD"] ?? "") {
            XCUIDevice.shared.orientation = .landscapeLeft
            print("HOLDING-LANDSCAPE"); Thread.sleep(forTimeInterval: hold)
            XCUIDevice.shared.orientation = .portrait
        }
    }

    // MARK: v3 popovers & orientation (4-part test-pattern long video, chrome pinned)

    static let icons = ["player.rate", "player.quality", "player.audio", "player.subtitles",
                        "player.danmaku", "player.episodes", "player.fullscreen"]

    func launchV3() {
        launch(["STV_FX_EPISODES": "4", "STV_FX_TITLE": "测试图案合集", "STV_KEEP_CHROME": "1"])
        XCTAssertTrue(el("player.progress").waitForExistence(timeout: 20), "player did not become ready")
    }
    func popoverGone(_ id: String) -> Bool {
        let p = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [expectation(for: p, evaluatedWith: el(id))], timeout: 4) == .completed
    }
    func scrimTap(landscape: Bool) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: landscape ? CGVector(dx: 0.2, dy: 0.5) : CGVector(dx: 0.85, dy: 0.18)).tap()
    }

    func testV3IconsAndPopoversPortrait() {
        launchV3()
        XCTAssertTrue(waitOrientation(landscape: false))
        // Seven equally spaced icons in one row.
        let frames = Self.icons.map { id -> CGRect in XCTAssertTrue(el(id).waitForExistence(timeout: 4), id); return el(id).frame }
        let ys = frames.map(\.midY), xs = frames.map(\.midX)
        XCTAssertLessThan((ys.max()! - ys.min()!), 2, "icons not on one row")
        let gaps = zip(xs.dropFirst(), xs).map { $0 - $1 }
        XCTAssertLessThan(gaps.max()! - gaps.min()!, 2, "icons not equally spaced: \(gaps)")
        XCTAssertTrue(el("player.time").exists && el("player.remaining").exists)
        XCTAssertTrue((el("player.remaining").label).hasPrefix("−"), "right time must be −remaining")

        // 倍速: pick 1.5× → closes, rate applied (icon shows 1.5×).
        el("player.rate").tap()
        XCTAssertTrue(el("player.popover.rates").waitForExistence(timeout: 3))
        let pf = el("player.popover.rates").frame, wf = app.windows.firstMatch.frame
        XCTAssertGreaterThan(pf.midY, wf.midY, "portrait popover should sit above the icon row")
        el("player.rate.1.5").tap()
        XCTAssertTrue(popoverGone("player.popover.rates"))
        XCTAssertTrue(el("player.rate").label.contains("1.5"), "rate icon: \(el("player.rate").label)")
        shot("v3_ui_rate_picked")

        // 画质: has a 播放源 section; scrim tap closes.
        el("player.quality").tap()
        XCTAssertTrue(el("player.popover.quality").waitForExistence(timeout: 3))
        XCTAssertTrue(el("player.stream").exists)
        scrimTap(landscape: false)
        XCTAssertTrue(popoverGone("player.popover.quality"), "scrim did not close 画质")

        // 选集 (long video → list): pick part 2.
        el("player.episodes").tap()
        XCTAssertTrue(el("player.popover.episodes").waitForExistence(timeout: 3))
        XCTAssertTrue(el("player.ep.2").waitForExistence(timeout: 3))
        el("player.ep.2").tap()
        XCTAssertTrue(popoverGone("player.popover.episodes"))
        // Reopen: part 2 is now the selected row.
        Thread.sleep(forTimeInterval: 1.5)
        el("player.episodes").tap()
        XCTAssertTrue(el("player.ep.2").waitForExistence(timeout: 3))
        XCTAssertTrue(el("player.ep.2").isSelected, "episode 2 not selected")
        XCTAssertFalse(el("player.ep.1").isSelected)
        scrimTap(landscape: false)
        XCTAssertTrue(popoverGone("player.popover.episodes"))

        // Only one popover at a time; same icon toggles closed.
        el("player.audio").tap()
        XCTAssertTrue(el("player.popover.audio").waitForExistence(timeout: 3))
        el("player.audio").tap()
        XCTAssertTrue(popoverGone("player.popover.audio"))
    }

    func testV3PopoversLandscapeAndBack() {
        launchV3()
        el("player.fullscreen").tap()
        XCTAssertTrue(waitOrientation(landscape: true), "横屏 button did not rotate")
        XCUIDevice.shared.orientation = .landscapeLeft   // keep the device in step so rotating back is a real change
        Thread.sleep(forTimeInterval: 0.8)
        for id in ["player.rate", "player.quality", "player.episodes", "player.lock", "player.exitFullscreen"] {
            XCTAssertTrue(el(id).waitForExistence(timeout: 4), "landscape chrome missing \(id)")
        }
        let wf = app.windows.firstMatch.frame
        // Landscape popovers hang from the top-right.
        el("player.episodes").tap()
        XCTAssertTrue(el("player.popover.episodes").waitForExistence(timeout: 3))
        let ef = el("player.popover.episodes").frame
        XCTAssertGreaterThan(ef.minX, wf.width * 0.4, "landscape 选集 should be on the right")
        XCTAssertLessThan(ef.minY, wf.height * 0.3)
        shot("v3_ui_landscape_episodes")
        scrimTap(landscape: true)
        XCTAssertTrue(popoverGone("player.popover.episodes"))

        el("player.rate").tap()
        XCTAssertTrue(el("player.popover.rates").waitForExistence(timeout: 3))
        for r in ["0.5", "0.75", "1.0", "1.25", "1.5", "2.0"] {
            XCTAssertTrue(el("player.rate.\(r)").isHittable, "landscape rate \(r) clipped")
        }
        el("player.rate.2.0").tap()
        XCTAssertTrue(popoverGone("player.popover.rates"))

        // Rotating the device while a popover is open closes it and keeps working.
        el("player.quality").tap()
        XCTAssertTrue(el("player.popover.quality").waitForExistence(timeout: 3))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitOrientation(landscape: false), "device rotation back not followed")
        XCTAssertTrue(popoverGone("player.popover.quality"), "rotation should close the popover")
        XCTAssertTrue(el("player.progress").waitForExistence(timeout: 4))
        XCTAssertTrue(el("player.fullscreen").waitForExistence(timeout: 4))
    }

    func testV3CenterControlsSkip() {
        launch(["STV_FX_EPISODES": "4", "STV_KEEP_CHROME": "1", "STV_SEEK": "10", "STV_PAUSE": "1"])
        XCTAssertTrue(el("player.progress").waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(el("player.playPause").waitForExistence(timeout: 6))
        XCTAssertTrue(el("player.back10").exists && el("player.fwd10").exists)
        let before = seconds(el("player.progress").value as? String ?? "")
        el("player.fwd10").tap()
        let after = seconds(el("player.progress").value as? String ?? "")
        XCTAssertGreaterThanOrEqual(after - before, 8, "⟳10 failed: \(before) → \(after)")
        el("player.back10").tap()
        XCTAssertLessThanOrEqual(seconds(el("player.progress").value as? String ?? ""), after - 7, "⟲10 failed")
    }
}
