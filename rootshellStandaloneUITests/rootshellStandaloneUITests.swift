import XCTest
import Darwin

/// Fork-only semantic regression coverage for the zmx multiplexer path.
///
/// These tests deliberately drive the same New Connection UI a user drives.
/// The fixture's control key is never passed to the app: the UI selects SSH
/// authentication method "None" and connects to the fixture's loopback port.
final class rootshellStandaloneUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.kk2.rootshell.localuitesthost")
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
        try FileManager.default.createDirectory(
            at: socketDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        app.launchArguments = [
            "-rootshell-zmx-ui-test",
            "-rootshell-zmx-ui-test-socket-directory", socketDirectory.path,
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launchEnvironment["ROOTSHELL_ZMX_UI_TEST"] = "1"
        app.launch()
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
        app.typeKey("t", modifierFlags: [.command])

        let localTerminals = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND value == %@", "terminal-readiness", "ready")
        )
        let twoLocals = NSPredicate(format: "count >= 2")
        try waitForPredicate(
            twoLocals,
            on: localTerminals,
            timeout: 15,
            context: "waiting for second local terminal after Cmd-T"
        )
        XCTAssertGreaterThanOrEqual(localTerminals.count, 2, "Cmd-T from SSH did not leave the new local terminal ready")
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
        guard prompt.buttons["Connect Once"].firstMatch.exists else { return false }

        // Other app alerts (including VNC trust and system permission alerts)
        // can also have similarly named controls. Require the app's specific
        // SSH host-key title before allowing this expected in-app sheet.
        return prompt.staticTexts["New SSH Host"].firstMatch.exists
            || prompt.label == "New SSH Host"
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
        timeout: TimeInterval = 15
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var nextInterruptionCheck = Date()
        var remoteReadyAppeared = false
        var promptTitle: XCUIElement?
        var action: XCUIElement?

        while Date() < deadline {
            remoteReadyAppeared = remoteReadyAppeared || remoteReadyTerminalExists()
            // Catalyst can flatten a SwiftUI alert into the application root
            // while also publishing a non-hittable Touch Bar mirror under the
            // first sheet. Require the exact app-owned title globally, then
            // choose the first hittable matching action instead of assuming
            // the first alert/sheet owns the interactive copy.
            let title = app.staticTexts["New SSH Host"].firstMatch
            if title.exists,
               let button = app.buttons.matching(
                NSPredicate(format: "label == %@", "Connect Once")
               ).allElementsBoundByIndex.first(where: { $0.isHittable }) {
                promptTitle = title
                action = button
            }
            if action != nil { break }
            if Date() >= nextInterruptionCheck {
                try triggerInterruptionMonitorCheck(context: "waiting for SSH host-key prompt")
                nextInterruptionCheck = Date().addingTimeInterval(1)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        guard let promptTitle, let action else {
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
        // the remote-ready assertion in the caller.
        let dismissed = NSPredicate(format: "exists == false")
        try waitForPredicate(
            dismissed,
            on: promptTitle,
            timeout: 10,
            context: "waiting for SSH host-key prompt dismissal"
        )
        guard dismissed.evaluate(with: promptTitle) else {
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

        return "appState=\(String(describing: app.state)); " +
            "remoteReadyAppeared=\(remoteReadyAppeared || remoteReadyNow); " +
            "handshake=\(handshakeState); " +
            "alert=\(conciseElementDescription(app.alerts.firstMatch)); " +
            "sheet=\(conciseElementDescription(app.sheets.firstMatch))"
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
        field.tap()
        field.typeKey("a", modifierFlags: [.command])
        field.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        field.typeText(value)
    }

    @MainActor
    private func openTabExpose() throws {
        app.typeKey("\\", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            try waitForExistence(tabExposeRoot(), timeout: 10, context: "waiting for Tab Exposé"),
            "Tab Exposé did not open"
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
