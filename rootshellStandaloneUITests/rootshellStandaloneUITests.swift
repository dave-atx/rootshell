import XCTest
import Darwin

/// Fork-only semantic regression coverage for the zmx multiplexer path.
///
/// These tests deliberately drive the same New Connection UI a user drives.
/// The fixture's control key is never passed to the app: the UI selects SSH
/// authentication method "None" and connects to the fixture's loopback port.
final class rootshellStandaloneUITests: XCTestCase {
    /// The ad-hoc runner (`scripts/test-macos-ui-local.sh`) rewrites the built
    /// host's identifier to a disposable one and resolves it by identifier. A
    /// paid-team run (`scripts/test-macos-ui-paid-team.sh`) leaves the app's
    /// real signed identity alone and lets XCTest resolve it from the test
    /// configuration's target-app path instead, so nothing depends on which
    /// copy of that identifier LaunchServices happens to prefer.
    private let app = ProcessInfo.processInfo.environment["ROOTSHELL_UI_TEST_USE_TARGET_APP"] == "1"
        ? XCUIApplication()
        : XCUIApplication(bundleIdentifier: "com.kk2.rootshell.localuitesthost")
    private var socketDirectory: URL!
    private var interruptionMonitor: NSObjectProtocol?
    private var unexpectedInterruption: String?

    private var runDirectory: URL? {
        guard let raw = ProcessInfo.processInfo.environment["ROOTSHELL_UI_TEST_RUN_DIRECTORY"],
              raw.hasPrefix("/private/tmp/rootshell-zmx-xcui-run."),
              !raw.contains("/../") else {
            return nil
        }
        let url = URL(fileURLWithPath: raw, isDirectory: true)
        guard url.deletingLastPathComponent().path == "/private/tmp" else { return nil }
        return url
    }

    private var fixtureHost: String {
        ProcessInfo.processInfo.environment["ZMX_FIXTURE_HOST"] ?? "127.0.0.1"
    }

    private var fixturePort: String {
        ProcessInfo.processInfo.environment["ZMX_FIXTURE_PORT"] ?? ""
    }

    private var fixtureUser: String {
        ProcessInfo.processInfo.environment["ZMX_FIXTURE_USERNAME"] ?? "zmx"
    }

    private var fixturePrefix: String {
        ProcessInfo.processInfo.environment["ZMX_FIXTURE_SESSION_PREFIX"] ?? "rs-xcui-missing"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        installUnexpectedInterruptionMonitor()
        if let runDirectory {
            socketDirectory = runDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        } else {
            // Keep direct Xcode invocations usable, but the scripted suite
            // always supplies a run directory so its trap can clean up after
            // interrupted test processes.
            socketDirectory = URL(
                fileURLWithPath: "/private/tmp/rootshell-zmx-xcui-\(UUID().uuidString)",
                isDirectory: true
            )
        }
        // The paid-team runner (`scripts/test-macos-ui-paid-team.sh`) keeps
        // the app's real signed entitlements instead of ad-hoc re-signing,
        // so Xcode's generated Runner is sandboxed and only holds a
        // read-only temporary exception for `/`: this process can see the
        // whole filesystem but cannot create anything under `/private/tmp`.
        // The ad-hoc runner (`scripts/test-macos-ui-local.sh`) re-signs with
        // an entitlements file that drops the sandbox key entirely, so it
        // never hits this. Rather than special-case the runner here, defer
        // to the app under test, which is not sandboxed and already creates
        // this exact directory as an intermediate of its own sterile-home
        // setup before its first scene is built — so tolerate precisely the
        // sandbox's EPERM refusal and confirm afterward that the app did the
        // work; anything else still means a genuinely broken run directory
        // and must fail loudly.
        var appMustCreateSocketDirectory = false
        do {
            try FileManager.default.createDirectory(
                at: socketDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            let nsError = error as NSError
            guard nsError.domain == NSCocoaErrorDomain,
                  nsError.code == CocoaError.fileWriteNoPermission.rawValue,
                  let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
                  underlying.domain == NSPOSIXErrorDomain,
                  underlying.code == Int(EPERM) else {
                throw error
            }
            appMustCreateSocketDirectory = true
        }
        app.launchArguments = [
            "-rootshell-zmx-ui-test",
            "-rootshell-zmx-ui-test-socket-directory", socketDirectory.path,
            "-ApplePersistenceIgnoreState", "YES",
            // Turns on SSHDebugLogger for the app under test. It writes to
            // `sterileHomeDirectory/.ghostty/ssh_debug.log`, i.e. inside this
            // run's own socket directory, so the log is collectable after the
            // run and cannot leak into the developer's real Documents.
            "-sshDebugLoggingEnabled", "YES"
        ]
        app.launchEnvironment["ROOTSHELL_ZMX_UI_TEST"] = "1"
        app.launch()
        if appMustCreateSocketDirectory {
            // Reads are unaffected by the sandbox (the read-only `/`
            // exception covers them), so this is a real check rather than a
            // formality: poll briefly rather than checking once, since the
            // app creates the directory during its own launch-time setup
            // and that race is what we're waiting out here.
            let deadline = Date().addingTimeInterval(5)
            var socketDirectoryExists = false
            repeat {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: socketDirectory.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    socketDirectoryExists = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            } while Date() < deadline
            XCTAssertTrue(
                socketDirectoryExists,
                "app under test did not create the UI-test socket directory at \(socketDirectory.path); "
                    + "the sandboxed test runner could not create it either"
            )
        }
        // A freshly launched app is not necessarily the frontmost one, and
        // the paid-team runner keeps the app's real signed identity rather
        // than ad-hoc re-signing it, so nothing about that identity forces
        // macOS to activate its window. Ask for activation explicitly: when
        // some other app owns focus, the first synthesized click lands as the
        // one that activates us rather than one the intended control sees.
        // Do not gate the suite on a frontmost check afterwards -- the root
        // Application element reports `isEnabled == false` here even in runs
        // where interaction then works, so it is not a usable activation
        // signal on Mac Catalyst.
        app.activate()
    }

    override func tearDownWithError() throws {
        // A connection can be paused on a host-key sheet while a failing test
        // unwinds. Resolve only this known prompt before termination so it
        // cannot remain on screen after the suite ends.
        try? acceptFreshHostKeyIfPresented(required: false, timeout: 2)
        if app.state != .notRunning {
            app.terminate()
        }
        if let socketDirectory {
            terminateOwnedHelper(at: socketDirectory)
            try? FileManager.default.removeItem(at: socketDirectory)
        }
        if let interruptionMonitor {
            removeUIInterruptionMonitor(interruptionMonitor)
            self.interruptionMonitor = nil
        }
    }

    @MainActor
    func testLaunchesLocalTerminal() throws {
        try waitForTerminal(state: "ready")
    }

    @MainActor
    func testSSHZmxExposeUsesRealConnectionUI() throws {
        try connectToFixture()
        let terminal = try waitForTerminal(state: "remote-ready")
        terminal.tap()
        terminal.typeText("ZMX_SESSION_PREFIX= zmx attach \(fixturePrefix)-expose-a\n")

        try openTabExpose()
        let root = tabExposeRoot()
        try waitForValue("multiplexer", on: root, timeout: 15)

        let session = tabExposeCell(named: "\(fixturePrefix)-expose-a")
        XCTAssertTrue(
            try waitForExistence(session, timeout: 15, context: "waiting for seeded zmx session"),
            "seeded zmx session was not shown in tab exposé"
        )
    }

    @MainActor
    func testCommandTFromSSHLeavesLocalTerminalReady() throws {
        try connectToFixture()
        let remoteTerminal = try waitForTerminal(state: "remote-ready")

        // The remote shell's /home/zmx working directory does not exist on
        // the Mac. A local tab must nevertheless be created and stay alive.
        // Explicitly focus the remote terminal: Cmd-T must be delivered from
        // that terminal rather than whichever SwiftUI control was last active.
        remoteTerminal.tap()
        // `File > New Tab` is the same `ghostty_newLocalShell` action Cmd-T is
        // bound to (CatalystAppDelegate.swift:1081); see `invokeMenuItem` for
        // why the chord itself cannot be used here.
        try invokeMenuItem("New Tab", in: "File")

        let localTerminals = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND value == %@", "terminal-readiness", "ready")
        )
        let twoLocals = NSPredicate(format: "count >= 2")
        // `waitForPredicate` itself never raises a failure on an ordinary
        // timeout (only an unexpected UI interruption makes it throw); a
        // plain timeout here falls straight through to the assertion below,
        // so that is the one place this test's failure is actually signaled
        // and the only place the diagnostics need to be attached.
        try waitForPredicate(
            twoLocals,
            on: localTerminals,
            timeout: 15,
            context: "waiting for second local terminal after Cmd-T"
        )
        XCTAssertGreaterThanOrEqual(
            localTerminals.count,
            2,
            "Cmd-T from SSH did not leave the new local terminal ready. " + localTerminalReadinessDiagnostics()
        )
    }

    @MainActor
    func testDetachThenTabExposeReturnsToLocal() throws {
        try connectToFixture()
        let terminal = try waitForTerminal(state: "remote-ready")

        let sessionName = "\(fixturePrefix)-detach"
        terminal.tap()
        terminal.typeText("ZMX_SESSION_PREFIX= zmx attach \(sessionName)\n")
        try waitForTerminal(state: "remote-ready")

        try openTabExpose()
        let root = tabExposeRoot()
        try waitForValue("multiplexer", on: root, timeout: 15)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

        terminal.tap()
        terminal.typeKey("\\", modifierFlags: [.control])
        try openTabExpose()
        try waitForValue("local", on: tabExposeRoot(), timeout: 15)
        XCTAssertFalse(tabExposeCell(named: sessionName).exists, "detached zmx session remained in local exposé")
    }

    // MARK: - UI flow

    private struct FixtureConnectionFailure: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    private func installUnexpectedInterruptionMonitor() {
        interruptionMonitor = addUIInterruptionMonitor(withDescription: "Unexpected system or foreign dialog") { [weak self] interruption in
            guard let self else { return false }

            // This is the one prompt this suite intentionally drives. Return
            // false even here: interruption monitors must never dismiss it.
            guard !self.isExpectedSSHHostKeyPrompt(interruption) else {
                return false
            }

            let description = self.conciseElementDescription(interruption)
            self.unexpectedInterruption = description
            XCTFail(
                "Unexpected UI interruption appeared: \(description). " +
                "The test did not dismiss it; resolve the system/privacy/foreign dialog before rerunning."
            )
            return false
        }
    }

    /// XCTest evaluates interruption monitors only while it attempts an UI
    /// interaction. A bare Shift key is inert for the app (it does not edit a
    /// field or activate a control), but makes a blocked wait observe any
    /// system, privacy, or foreign-app prompt instead of timing out vaguely.
    private func triggerInterruptionMonitorCheck(context: String) throws {
        app.typeKey(XCUIKeyboardKey.shift, modifierFlags: [])
        if let unexpectedInterruption {
            throw FixtureConnectionFailure(
                message: "Unexpected UI interruption while \(context): \(unexpectedInterruption). " +
                    "The test did not dismiss it."
            )
        }
    }

    private func isExpectedSSHHostKeyPrompt(_ prompt: XCUIElement) -> Bool {
        // A failing run's own screen recording proves `Connect Once` is on
        // screen and hittable while a `label`-only match still missed it: the
        // dialog is an AppKit-bridged sheet (`identifier=_NS:87, label=alert`)
        // whose buttons expose their text as `title`, not `label`. Match
        // whichever attribute the bridge populated - `title`, `label`, or
        // `identifier` - rather than betting on one. Prefer a hittable match,
        // but do not let `isHittable` alone - itself a plausible suspect on a
        // Catalyst sheet - gate recognition of the prompt.
        let candidates = prompt.buttons.matching(
            NSPredicate(
                format: "label == %@ OR title == %@ OR identifier == %@",
                "Connect Once", "Connect Once", "Connect Once"
            )
        ).allElementsBoundByIndex
        guard candidates.contains(where: { $0.isHittable }) || candidates.contains(where: { $0.exists }) else {
            return false
        }

        // Other app alerts (including VNC trust and system permission
        // alerts) can also have similarly named controls, and the
        // host-key-*changed* warning shares this same button label. That
        // warning must never be auto-accepted, so exclude it explicitly by
        // the one text that is unique to it - checked against both `label`
        // and `title`, since the same AppKit bridge exposes this prompt's
        // text identically to the button's.
        let keyChanged = NSPredicate(
            format: "label BEGINSWITH %@ OR title BEGINSWITH %@",
            "⚠️ WARNING: Host Key Changed", "⚠️ WARNING: Host Key Changed"
        )
        return !(prompt.staticTexts.matching(keyChanged).firstMatch.exists || keyChanged.evaluate(with: prompt))
    }

    @MainActor
    private func connectToFixture() throws {
        XCTAssertFalse(fixturePort.isEmpty, "fixture environment did not provide a port")
        try waitForTerminal(state: "ready")

        let newConnection = app.descendants(matching: .any).matching(identifier: "new-connection").firstMatch
        XCTAssertTrue(
            try waitForExistence(newConnection, timeout: 15, context: "waiting for New Connection control"),
            "New Connection control did not appear"
        )
        newConnection.tap()

        let host = field("ssh-host")
        XCTAssertTrue(
            try waitForExistence(host, timeout: 10, context: "waiting for SSH host field"),
            "SSH host field did not appear"
        )
        clearAndType(host, fixtureHost)

        let port = field("ssh-port")
        clearAndType(port, fixturePort)

        let username = field("ssh-username")
        clearAndType(username, fixtureUser)

        let authNone = app.descendants(matching: .any).matching(identifier: "ssh-auth-none").firstMatch
        if try waitForExistence(authNone, timeout: 5, context: "waiting for SSH None authentication option"), authNone.isHittable {
            authNone.tap()
        } else {
            // SwiftUI's segmented Picker can flatten the Text identifier on
            // Catalyst. The visible label is still the real UI control.
            let none = app.buttons["None"]
            XCTAssertTrue(
                try waitForExistence(none, timeout: 5, context: "waiting for visible None authentication option"),
                "SSH None authentication option did not appear"
            )
            none.tap()
        }

        let connect = app.descendants(matching: .any).matching(identifier: "ssh-connect").firstMatch
        XCTAssertTrue(
            try waitForExistence(connect, timeout: 10, context: "waiting for SSH Connect button"),
            "SSH Connect button did not appear"
        )
        XCTAssertTrue(connect.isEnabled, "SSH Connect button remained disabled")
        connect.tap()

        try acceptFreshHostKeyIfPresented()
    }

    /// Accept the fixture's newly generated key, and only after the visible
    /// prompt has actually been dismissed let the connection readiness wait
    /// begin. SwiftUI alerts are exposed as `alerts` on some Catalyst
    /// versions and as `sheets` on others; the latter also contains a mirrored
    /// Touch Bar subtree, so the button is always scoped to the prompt.
    private func acceptFreshHostKeyIfPresented(
        required: Bool = true,
        // The fixture's first SSH handshake to the containerized host takes
        // roughly 15s to reach the host-key prompt, so a 15s budget raced
        // that appearance instead of waiting for it: a contact sheet of a
        // failing run's recording shows the dialog only shows up around the
        // 15s mark and then sits unchanged, unmatched, for the rest of the
        // test. 60s gives the handshake room with real margin instead of
        // lining the budget up with the thing it is supposed to wait for.
        timeout: TimeInterval = 60
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var nextInterruptionCheck = Date()
        var remoteReadyAppeared = false
        var action: XCUIElement?

        while Date() < deadline {
            remoteReadyAppeared = remoteReadyAppeared || remoteReadyTerminalExists()
            // A failing run's screen recording proves the dialog is fully on
            // screen, correctly populated, and offering `Connect Once` while
            // this loop still misses it on `label` alone: the dialog is an
            // AppKit-bridged sheet whose buttons expose their text as
            // `title`, with `label` left empty. Match whichever attribute is
            // populated - `title`, `label`, or `identifier` - rather than
            // betting on one. Prefer a hittable match, but `isHittable` is
            // itself a plausible suspect on a Catalyst sheet, so fall back
            // to the first button that merely exists rather than let that
            // state block the whole suite.
            let candidates = app.buttons.matching(
                NSPredicate(
                    format: "label == %@ OR title == %@ OR identifier == %@",
                    "Connect Once", "Connect Once", "Connect Once"
                )
            ).allElementsBoundByIndex
            if let candidate = candidates.first(where: { $0.isHittable }) ?? candidates.first(where: { $0.exists }) {
                // Never auto-accept the host-key-*changed* warning, which
                // shares this same button text. Guard on the one text that
                // is unique to it, checked against both `label` and `title`
                // for the same reason the button match above is.
                let keyChanged = app.staticTexts.matching(
                    NSPredicate(
                        format: "label BEGINSWITH %@ OR title BEGINSWITH %@",
                        "⚠️ WARNING: Host Key Changed", "⚠️ WARNING: Host Key Changed"
                    )
                ).firstMatch.exists
                if !keyChanged {
                    action = candidate
                }
            }
            if action != nil { break }
            if Date() >= nextInterruptionCheck {
                try triggerInterruptionMonitorCheck(context: "waiting for SSH host-key prompt")
                nextInterruptionCheck = Date().addingTimeInterval(1)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        guard let action else {
            if required {
                throw FixtureConnectionFailure(
                    message: "Fresh SSH fixture connection never exposed the required Connect Once action. " +
                        fixtureConnectionDiagnostics(remoteReadyAppeared: remoteReadyAppeared)
                )
            }
            return
        }

        action.tap()

        // Tapping the action resumes the SSH continuation, but SwiftUI may
        // animate the alert away afterwards. Do not race that dismissal with
        // the remote-ready assertion in the caller. Watch the button itself
        // rather than a title element: the title is the element that proved
        // unreliable above, so the button stays the trustworthy handle for
        // dismissal too.
        let dismissed = NSPredicate(format: "exists == false")
        try waitForPredicate(
            dismissed,
            on: action,
            timeout: 10,
            context: "waiting for SSH host-key prompt dismissal"
        )
        guard dismissed.evaluate(with: action) else {
            throw FixtureConnectionFailure(
                message: "SSH host-key prompt remained visible after Connect Once. " +
                    fixtureConnectionDiagnostics(remoteReadyAppeared: remoteReadyTerminalExists())
            )
        }
    }

    private func remoteReadyTerminalExists() -> Bool {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND value == %@", "terminal-readiness", "remote-ready")
        ).firstMatch.exists
    }

    /// Keep failure diagnostics deliberately small. The full accessibility
    /// hierarchy can be megabytes on Catalyst and obscures the actual SSH
    /// state that explains a fixture connection timeout.
    private func fixtureConnectionDiagnostics(remoteReadyAppeared: Bool) -> String {
        let remoteReadyNow = remoteReadyTerminalExists()
        let hostKeyVisible = isExpectedSSHHostKeyPrompt(app.alerts.firstMatch)
            || isExpectedSSHHostKeyPrompt(app.sheets.firstMatch)
        let handshakeState: String
        if remoteReadyAppeared || remoteReadyNow {
            handshakeState = "remote-ready appeared before this failure"
        } else if hostKeyVisible {
            handshakeState = "waiting at the SSH host-key confirmation"
        } else {
            handshakeState = "remote-ready never appeared; SSH handshake stalled"
        }

        let base = "appState=\(String(describing: app.state)); " +
            "remoteReadyAppeared=\(remoteReadyAppeared || remoteReadyNow); " +
            "handshake=\(handshakeState); " +
            "alert=\(conciseElementDescription(app.alerts.firstMatch)); " +
            "sheet=\(conciseElementDescription(app.sheets.firstMatch))"

        // The prompt is visibly on screen in a failing run's own recording
        // while every query above reports it absent, so when that happens
        // the labels our queries actually see are the missing evidence -
        // append them so the next run can identify a correct query instead
        // of guessing blind again.
        guard !hostKeyVisible else { return base }
        return base + "; " + fixtureConnectionElementInventory()
    }

    /// Truncate `text` to `limit` characters, marking a cut with an
    /// ellipsis. Shared by `fixtureConnectionElementInventory` and
    /// `localTerminalReadinessDiagnostics` so this suite has one algorithm
    /// for keeping failure-message text bounded, not two mildly different
    /// ones.
    private func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]) + "…"
    }

    /// Dump the labels/states our queries currently see for the controls
    /// most likely to explain a missed host-key prompt. Exists because the
    /// recording proves the dialog is fully on screen while the targeted
    /// queries above miss it - the full Catalyst hierarchy can be megabytes
    /// (see the comment on `fixtureConnectionDiagnostics`), so this stays
    /// bounded to the small set of element kinds the detection logic
    /// actually queries.
    private func fixtureConnectionElementInventory() -> String {
        let maxEntries = 40
        // An empty `label` previously hid a populated `title` - the exact gap
        // that cost an extra run to diagnose the AppKit-bridged host-key
        // sheet above. Each entry now carries identifier/label/title/value
        // instead of just label, so halve the per-string cap to keep the
        // overall message from growing with it.
        let maxAttributeLength = 30

        func describe(_ element: XCUIElement) -> String {
            "(identifier=\"\(truncated(element.identifier, limit: maxAttributeLength))\", " +
                "label=\"\(truncated(element.label, limit: maxAttributeLength))\", " +
                "title=\"\(truncated(element.title, limit: maxAttributeLength))\", " +
                "value=\"\(truncated(String(describing: element.value), limit: maxAttributeLength))\")"
        }

        func list(_ elements: [XCUIElement], describe: (XCUIElement) -> String) -> String {
            let entries = elements.prefix(maxEntries).map(describe).joined(separator: ", ")
            let note = elements.count > maxEntries
                ? " (truncated to first \(maxEntries) of \(elements.count))"
                : ""
            return (entries.isEmpty ? "none" : entries) + note
        }

        let staticTexts = app.staticTexts.allElementsBoundByIndex
        let buttons = app.buttons.allElementsBoundByIndex
        let sheets = app.sheets.allElementsBoundByIndex
        let alerts = app.alerts.allElementsBoundByIndex

        let staticTextList = list(staticTexts, describe: describe)
        let buttonList = list(buttons) {
            describe($0) + " (exists=\($0.exists), isHittable=\($0.isHittable))"
        }
        let sheetTypes = list(sheets) { String(describing: $0.elementType) }
        let alertTypes = list(alerts) { String(describing: $0.elementType) }

        return "staticTexts=[\(staticTextList)]; buttons=[\(buttonList)]; " +
            "sheets(count=\(sheets.count), types=[\(sheetTypes)]); " +
            "alerts(count=\(alerts.count), types=[\(alertTypes)])"
    }

    private func conciseElementDescription(_ element: XCUIElement) -> String {
        guard element.exists else { return "absent" }

        let raw = "type=\(String(describing: element.elementType)), " +
            "identifier=\(element.identifier), label=\(element.label), " +
            "value=\(String(describing: element.value))"
        let limit = 240
        guard raw.count > limit else { return raw }
        let end = raw.index(raw.startIndex, offsetBy: limit)
        return String(raw[..<end]) + "…"
    }

    /// Diagnose why `testCommandTFromSSHLeavesLocalTerminalReady`'s wait for
    /// a second local terminal-readiness element failed. A bare
    /// `("0") is less than ("2")` cannot tell apart: (a) no new tab was
    /// created at all, (b) a tab was created but its session never reached
    /// `sessionDidBecomeReady()` (TerminalView+SessionHost.swift), (c) the
    /// new tab came up as something other than a local shell, or (d) the
    /// whole app dropped out of the accessibility tree (screen locked / app
    /// backgrounded) - each needs a different fix, and a suite run costs
    /// ~7 minutes of attended keyboard time, so the next run must be able to
    /// tell them apart on its own. Mirrors `fixtureConnectionDiagnostics`'s
    /// contract: cheap, bounded, and must never itself throw or hang the
    /// test, so every query here is capped the same way that one is.
    private func localTerminalReadinessDiagnostics() -> String {
        let maxEntries = 15
        let maxAttributeLength = 30

        // 1. Every `terminal-readiness` element regardless of value. Both
        // the original local terminal and the SSH tab's terminal are marked
        // once each from `ForkUITestConfiguration.markTerminal`
        // (ForkUITestConfiguration.swift:189-196), and an unselected tab
        // stays in the tree too - `MainView+TerminalContent.swift:980-1093`
        // only applies `.opacity(0)`/`.allowsHitTesting(false)` to it, never
        // `isHidden` or `accessibilityElementsHidden` - so this list should
        // show every terminal that exists, ready or not. 1 "ready" + 1
        // "remote-ready" means no new tab was created; a third element with
        // a value other than "ready" means the tab exists but did not come
        // up as a ready local shell - that is (a)/(b) vs (c).
        let readinessElements = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "terminal-readiness")
        ).allElementsBoundByIndex
        let readinessList = readinessElements.prefix(maxEntries).enumerated().map { index, element in
            "[\(index)] value=\"\(truncated(String(describing: element.value), limit: maxAttributeLength))\", " +
                "isHittable=\(element.isHittable), frame=\(element.frame)"
        }.joined(separator: ", ")
        let readinessNote = readinessElements.count > maxEntries
            ? " (truncated to first \(maxEntries) of \(readinessElements.count))"
            : ""

        // 2. Whether the app dropped out of the accessibility tree entirely
        // - case (d). Read even when the query above finds nothing: a
        // locked screen or a backgrounded app is exactly the case where
        // `readinessElements` legitimately comes back empty rather than
        // proving (a)/(b)/(c). Deliberately not gated on `app.isEnabled`:
        // the root Application element reports Disabled even in healthy
        // runs (see the comment in `setUpWithError`), so it is not a usable
        // signal here either.
        let appExists = app.exists
        let appState = String(describing: app.state)

        // 3. Bounded inventory of what the query actually sees, so a
        // totally empty tree (case d) reads differently from a populated
        // tree that simply lacks a second ready terminal. Same shape as
        // `fixtureConnectionElementInventory`, just capped to this
        // assertion's own smaller budget.
        let windows = app.windows.allElementsBoundByIndex
        let buttons = app.buttons.allElementsBoundByIndex
        let staticTexts = app.staticTexts.allElementsBoundByIndex
        let staticTextLabels = staticTexts.prefix(maxEntries)
            .map { "\"\(truncated($0.label, limit: maxAttributeLength))\"" }
            .joined(separator: ", ")
        let staticTextNote = staticTexts.count > maxEntries
            ? " (truncated to first \(maxEntries) of \(staticTexts.count))"
            : ""

        // 4. Any alert or sheet on screen - a stray modal is a plausible
        // cause of a stalled New Tab action.
        let alertDescription = conciseElementDescription(app.alerts.firstMatch)
        let sheetDescription = conciseElementDescription(app.sheets.firstMatch)

        return "terminalReadinessElements=[\(readinessList.isEmpty ? "none" : readinessList)]\(readinessNote); " +
            "appExists=\(appExists); appState=\(appState); " +
            "windows=\(windows.count), buttons=\(buttons.count), staticTexts=\(staticTexts.count); " +
            "staticTextLabels=[\(staticTextLabels.isEmpty ? "none" : staticTextLabels)]\(staticTextNote); " +
            "alert=\(alertDescription); sheet=\(sheetDescription)"
    }

    /// Tear down only a helper whose live command line still points at this
    /// test's private socket directory. The shell runner implements the same
    /// check as a crash/interruption backstop; neither path enumerates or
    /// signals helpers outside this launch contract.
    private func terminateOwnedHelper(at directory: URL) {
        let marker = directory.appendingPathComponent("rootshell-helper.pid", isDirectory: false)
        guard let text = try? String(contentsOf: marker, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1,
              helperCommandMatches(pid: pid, socketDirectory: directory.path) else {
            return
        }

        _ = kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, helperCommandMatches(pid: pid, socketDirectory: directory.path) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if helperCommandMatches(pid: pid, socketDirectory: directory.path) {
            _ = kill(pid, SIGKILL)
        }
    }

    private func helperCommandMatches(pid: pid_t, socketDirectory: String) -> Bool {
        // Foundation.Process is unavailable to Mac Catalyst test bundles. Read
        // the kernel's argv buffer directly instead of invoking `ps`; this also
        // avoids accepting a merely similar process name or a directory that is
        // only a substring of the owned socket path.
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else {
            return false
        }

        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &bytes, &size, nil, 0) == 0 else {
            return false
        }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { destination in
            bytes.withUnsafeBytes { source in
                memcpy(destination.baseAddress!, source.baseAddress!, MemoryLayout<Int32>.size)
            }
        }
        guard argc > 0, argc <= 4096 else { return false }

        var offset = MemoryLayout<Int32>.size
        guard let executable = readProcArgString(bytes, offset: &offset),
              URL(fileURLWithPath: executable).lastPathComponent == "rootshell-helper" else {
            return false
        }

        // KERN_PROCARGS2 can include padding NULs between the executable path
        // and argv[0]. Skip those before reading exactly argc argv strings.
        while offset < bytes.count, bytes[offset] == 0 {
            offset += 1
        }

        var arguments: [String] = []
        arguments.reserveCapacity(Int(argc))
        for _ in 0 ..< argc {
            guard let argument = readProcArgString(bytes, offset: &offset) else {
                return false
            }
            arguments.append(argument)
        }

        guard arguments.count >= 3 else { return false }
        for index in 0 ..< arguments.count - 1 {
            if arguments[index] == "--socket-directory",
               arguments[index + 1] == socketDirectory {
                return true
            }
        }
        return false
    }

    private func readProcArgString(_ bytes: [UInt8], offset: inout Int) -> String? {
        guard offset < bytes.count else { return nil }
        let start = offset
        while offset < bytes.count, bytes[offset] != 0 {
            offset += 1
        }
        guard offset < bytes.count else { return nil }
        let string = String(bytes: bytes[start ..< offset], encoding: .utf8)
        offset += 1
        return string
    }

    private func waitForExistence(
        _ element: XCUIElement,
        timeout: TimeInterval,
        context: String
    ) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var nextInterruptionCheck = Date()
        while Date() < deadline {
            if element.exists { return true }
            if Date() >= nextInterruptionCheck {
                try triggerInterruptionMonitorCheck(context: context)
                nextInterruptionCheck = Date().addingTimeInterval(1)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists
    }

    private func waitForPredicate(
        _ predicate: NSPredicate,
        on object: Any,
        timeout: TimeInterval,
        context: String
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var nextInterruptionCheck = Date()
        while Date() < deadline {
            if predicate.evaluate(with: object) { return }
            if Date() >= nextInterruptionCheck {
                try triggerInterruptionMonitorCheck(context: context)
                nextInterruptionCheck = Date().addingTimeInterval(1)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    @MainActor
    private func waitForTerminal(state: String, timeout: TimeInterval = 30) throws -> XCUIElement {
        let terminal = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND value == %@", "terminal-readiness", state)
        ).firstMatch

        let appeared = try waitForExistence(
            terminal,
            timeout: timeout,
            context: "waiting for \(state) terminal readiness"
        )
        if state == "remote-ready", !appeared {
            throw FixtureConnectionFailure(
                message: "Remote terminal readiness element did not appear. " +
                    fixtureConnectionDiagnostics(remoteReadyAppeared: false)
            )
        }
        XCTAssertTrue(appeared, "terminal readiness element did not appear")
        return terminal
    }

    @MainActor
    private func waitForValue(_ value: String, on element: XCUIElement, timeout: TimeInterval) throws {
        let predicate = NSPredicate(format: "value == %@", value)
        try waitForPredicate(
            predicate,
            on: element,
            timeout: timeout,
            context: "waiting for accessibility value \(value)"
        )
        XCTAssertTrue(predicate.evaluate(with: element), "expected accessibility value \(value), got \(String(describing: element.value))")
    }

    @MainActor
    private func field(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func clearAndType(_ field: XCUIElement, _ value: String) {
        // `hasFocus` is unavailable at runtime on macOS ("Calling hasFocus
        // on element is not supported on a macOS"), so there is no public way
        // to confirm the field took keyboard focus before typing. The tap is
        // the whole contract; `app.activate()` in setUpWithError is what keeps
        // the first one from being spent activating the app instead.
        field.tap()
        field.typeKey("a", modifierFlags: [.command])
        field.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        field.typeText(value)
    }

    /// Invoke a Catalyst menu-bar command.
    ///
    /// Synthesized Cmd-chords do not reach the app's `UIKeyCommand`s while a
    /// terminal holds first responder: Cmd-T and Cmd-Shift-A both landed as
    /// no-ops, leaving no new tab and no exposé, with the app frontmost and
    /// plain `typeText` into the same terminal working fine. The menu bar
    /// dispatches the identical selectors through `sendAction`, which does not
    /// depend on the responder chain, so drive that instead.
    @MainActor
    private func invokeMenuItem(_ item: String, in menu: String) throws {
        let barItem = app.menuBars.menuBarItems[menu]
        XCTAssertTrue(
            try waitForExistence(barItem, timeout: 10, context: "waiting for the \(menu) menu"),
            "\(menu) menu is not in the menu bar"
        )
        barItem.tap()
        let menuItem = app.menuItems[item]
        XCTAssertTrue(
            try waitForExistence(menuItem, timeout: 10, context: "waiting for \(menu) > \(item)"),
            "\(menu) > \(item) is not in the menu"
        )
        menuItem.tap()
    }

    @MainActor
    private func openTabExpose() throws {
        // Tab Exposé is `toggle_tab_expose` — the Cmd-Shift-A keybind
        // (KeybindManager.swift:141) and the Tabs menu item
        // (CatalystAppDelegate.swift:1491). Cmd-Shift-Backslash, which this
        // used to send, is a different action entirely: `toggle_tab_switcher`,
        // the vertical tab bar.
        try invokeMenuItem("Tab Exposé", in: "Tabs")
        // `tab-expose-root` is assigned in TabExposeView.init and stays in the
        // accessibility tree while the overlay is hidden, so waiting for the
        // element to exist proves nothing and always succeeds. The
        // accessibility value is the real open/closed signal: the controller
        // sets it on activation and clears it on dismissal.
        let root = tabExposeRoot()
        let opened = NSPredicate(format: "value == %@ OR value == %@", "multiplexer", "local")
        try waitForPredicate(opened, on: root, timeout: 10, context: "waiting for Tab Exposé")
        XCTAssertTrue(
            opened.evaluate(with: root),
            "Tab Exposé did not open (accessibility value \(String(describing: root.value)))"
        )
    }

    @MainActor
    private func tabExposeRoot() -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "tab-expose-root").firstMatch
    }

    @MainActor
    private func tabExposeCell(named name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "tab-expose-zmx-session-\(name)").firstMatch
    }
}
