import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { print("  PASS  \(name)") }
    else { failures += 1; print("  FAIL  \(name)  \(detail())") }
}

let adapter = ZmxExposeAdapter()
let n = "abc123"
let TAB = "\t"

/// Assemble exactly what tickScript's output looks like.
func response(rows: [String], captures: [(String, String)], endMarker: Bool = true) -> String {
    var out = MuxScript.begin(n) + "\n"
    out += MuxScript.topology(n) + "\n"
    out += "::SESSIONS::\n"
    for r in rows { out += r + "\n" }
    for (id, body) in captures {
        out += "::MX_P_\(n):\(id):::\n"
        out += body + "\n"
    }
    if endMarker { out += MuxScript.end(n) + "\n" }
    return out
}

func row(_ name: String, pid: Int, clients: Int, cwd: String? = nil, cmd: String? = nil) -> String {
    var r = "  name=\(name)\(TAB)pid=\(pid)\(TAB)clients=\(clients)\(TAB)created=\(Int(Date().timeIntervalSince1970) - 600)"
    if let cwd { r += "\(TAB)cwd=\(cwd)" }
    if let cmd { r += "\(TAB)cmd=\(cmd)" }
    return r
}

print("\n== 1. three sessions, two captured ==")
do {
    let out = response(
        rows: [row("alpha", pid: 1, clients: 1, cwd: "file://fixture-host/home/tester/src"),
               row("beta",  pid: 2, clients: 0),
               row("gamma", pid: 3, clients: 2, cmd: "vim notes.md")],
        captures: [("alpha", "\u{1B}[32malpha screen\u{1B}[0m\nline two"),
                   ("gamma", "gamma screen")])
    guard let r = adapter.parseTick(output: out, session: "alpha", nonce: n) else {
        failures += 1; print("  FAIL  parseTick returned nil"); exit(1)
    }
    check("3 tabs", r.snapshot.tabs.count == 3, "got \(r.snapshot.tabs.count)")
    check("list order preserved", r.snapshot.tabs.map(\.id) == ["alpha","beta","gamma"], "got \(r.snapshot.tabs.map(\.id))")
    check("activeTabID == alpha", r.snapshot.activeTabID == "alpha", "got \(String(describing: r.snapshot.activeTabID))")
    check("alpha isActive", r.snapshot.tabs[0].isActive == true)
    check("beta not active", r.snapshot.tabs[1].isActive == false)
    check("title == name", r.snapshot.tabs[2].title == "gamma")
    check("one pane per tab", r.snapshot.tabs.allSatisfy { $0.panes.count == 1 })
    check("pane id == tab id", r.snapshot.tabs.allSatisfy { $0.panes[0].id == $0.id })
    check("frame keys match pane ids", Set(r.frames.keys).isSubset(of: Set(r.snapshot.allPanes.map(\.id))), "frames=\(Set(r.frames.keys))")
    check("frames only for captured", Set(r.frames.keys) == ["alpha","gamma"], "got \(Set(r.frames.keys))")
    check("gamma badge shows 2 clients", r.snapshot.tabs[2].badge?.contains("2") == true, "got \(String(describing: r.snapshot.tabs[2].badge))")
    check("alpha badge nil (1 client)", r.snapshot.tabs[0].badge == nil, "got \(String(describing: r.snapshot.tabs[0].badge))")
    check("pane title from cmd", r.snapshot.tabs[2].panes[0].title == "vim notes.md", "got \(String(describing: r.snapshot.tabs[2].panes[0].title))")
    // Narrow captures (a dozen columns, two lines) floor to the 80x24 floor;
    // beta was never fetched, so it gets the no-capture-yet fallback (120x24)
    // rather than the floor.
    check("captured session's narrow content floors to 80x24", r.snapshot.tabs[0].cols == 80 && r.snapshot.tabs[0].rows == 24, "alpha grid=\(r.snapshot.tabs[0].cols)x\(r.snapshot.tabs[0].rows)")
    check("uncaptured session falls back to 120x24", r.snapshot.tabs[1].cols == 120 && r.snapshot.tabs[1].rows == 24, "beta grid=\(r.snapshot.tabs[1].cols)x\(r.snapshot.tabs[1].rows)")
    check("rect fills tab", r.snapshot.tabs[0].panes[0].rect == MuxCellRect(x:0,y:0,width:80,height:24))
    check("not truncated", r.truncated == false)
    check("ansi ends with SGR reset", r.frames["alpha"]?.ansi.hasSuffix("\u{1B}[0m") == true)
}

print("\n== 2. erase-display trim keeps only the last screen ==")
do {
    let body = "OLD SCROLLBACK\n\u{1B}[2Jmiddle junk\n\u{1B}[2JFINAL SCREEN\nsecond row"
    let out = response(rows: [row("s", pid: 1, clients: 1)], captures: [("s", body)])
    guard let r = adapter.parseTick(output: out, session: "s", nonce: n) else {
        failures += 1; print("  FAIL  nil"); exit(1)
    }
    let ansi = r.frames["s"]?.ansi ?? ""
    check("keeps text after LAST 2J", ansi.hasPrefix("FINAL SCREEN"), "got \(ansi.prefix(40).debugDescription)")
    check("drops earlier scrollback", !ansi.contains("OLD SCROLLBACK") && !ansi.contains("middle junk"))
}

print("\n== 3. unsupported marker in the prelude kills the tick ==")
do {
    var out = MuxScript.begin(n) + "\n" + MuxScript.unsupportedMarker + "\n"
    out += MuxScript.topology(n) + "\n::SESSIONS::\n" + row("s", pid:1, clients:1) + "\n" + MuxScript.end(n) + "\n"
    check("parseTick nil", adapter.parseTick(output: out, session: nil, nonce: n) == nil)
}

print("\n== 4. unsupported marker in PANE CONTENT must not kill the tick ==")
do {
    let out = response(rows: [row("s", pid: 1, clients: 1)],
                       captures: [("s", "a log line containing \(MuxScript.unsupportedMarker) verbatim")])
    let r = adapter.parseTick(output: out, session: "s", nonce: n)
    check("parseTick non-nil", r != nil)
    check("marker survives as content", r?.frames["s"]?.ansi.contains(MuxScript.unsupportedMarker) == true)
}

print("\n== 4b. detached bound session makes the tick unusable ==")
do {
    let out = response(rows: [row("other", pid: 2, clients: 1),
                              row("detached", pid: 1, clients: 0)], captures: [])
    check("parseTick nil for detached bound session",
          adapter.parseTick(output: out, session: "detached", nonce: n) == nil)
    check("unrelated live session remains usable",
          adapter.parseTick(output: out, session: "other", nonce: n) != nil)
    let exited = response(rows: [row("other", pid: 2, clients: 1)], captures: [])
    check("parseTick nil when bound session exited",
          adapter.parseTick(output: exited, session: "detached", nonce: n) == nil)
    let truncated = response(rows: [row("detached", pid: 1, clients: 0)], captures: [], endMarker: false)
    check("truncated listing does not prove detachment",
          adapter.parseTick(output: truncated, session: "detached", nonce: n) != nil)
}

print("\n== 5. truncation drops the incomplete last pane ==")
do {
    let out = response(rows: [row("a", pid:1, clients:1), row("b", pid:2, clients:1)],
                       captures: [("a", "complete capture"), ("b", "cut off here")],
                       endMarker: false)
    guard let r = adapter.parseTick(output: out, session: "a", nonce: n) else {
        failures += 1; print("  FAIL  nil"); exit(1)
    }
    check("truncated flag set", r.truncated == true)
    check("both tabs still listed", r.snapshot.tabs.count == 2, "got \(r.snapshot.tabs.count)")
    check("complete pane survives", r.frames["a"] != nil)
    check("incomplete pane dropped", r.frames["b"] == nil, "frames=\(Set(r.frames.keys))")
}

print("\n== 6. error rows never become tabs ==")
do {
    let out = response(rows: ["  name=dead\(TAB)err=ConnectionRefused\(TAB)status=cleaning up",
                              row("live", pid: 1, clients: 1)],
                       captures: [])
    guard let r = adapter.parseTick(output: out, session: "live", nonce: n) else {
        failures += 1; print("  FAIL  nil"); exit(1)
    }
    check("only the live session", r.snapshot.tabs.map(\.id) == ["live"], "got \(r.snapshot.tabs.map(\.id))")
}

print("\n== 7. empty capture yields a tab but no frame ==")
do {
    let out = response(rows: [row("s", pid:1, clients:1)], captures: [("s", "")])
    guard let r = adapter.parseTick(output: out, session: "s", nonce: n) else {
        failures += 1; print("  FAIL  nil"); exit(1)
    }
    check("tab present", r.snapshot.tabs.count == 1)
    check("no frame (empty is a failed read, not a blank screen)", r.frames["s"] == nil, "got \(String(describing: r.frames["s"]?.ansi))")
}

print("\n== 8. focusScript ==")
do {
    let live = adapter.focusScript(session: "current", tabID: "target")
    check("exports ZMX_SESSION", live.contains("ZMX_SESSION="))
    check("neutralises the prefix", live.contains("ZMX_SESSION_PREFIX="))
    check("runs zmx attach", live.contains("zmx attach"))
    check("names the target", live.contains("target"))
    check("lists before the switch", live.contains("::MX_FOCUS_BEFORE::"))
    check("lists after the switch", live.contains("::MX_FOCUS_AFTER::"))
    check("before-listing precedes the attach",
          live.range(of: "::MX_FOCUS_BEFORE::").map { $0.lowerBound } ?? live.endIndex
            < live.range(of: "zmx attach \"target\"").map { $0.lowerBound } ?? live.startIndex)
    check("attach precedes the after-listing",
          live.range(of: "zmx attach \"target\"").map { $0.lowerBound } ?? live.endIndex
            < live.range(of: "::MX_FOCUS_AFTER::").map { $0.lowerBound } ?? live.startIndex)
    check("pauses before re-listing", live.contains("sleep"))
    for (label, s) in [("nil session", adapter.focusScript(session: nil, tabID: "t")),
                       ("empty session", adapter.focusScript(session: "", tabID: "t")),
                       ("same session", adapter.focusScript(session: "t", tabID: "t"))] {
        check("\(label) is inert", !s.contains("zmx attach"), "got \(s)")
        check("\(label) carries no verification markers", !s.contains("::MX_FOCUS_BEFORE::"), "got \(s)")
    }
}

print("\n== 8b. parseFocusResult: the no-op cases never need the reply ==")
do {
    for (label, sessionArg) in [("nil session", Optional<String>.none), ("empty session", ""), ("same session", "t")] {
        check("\(label) reports success from ANY output, even garbage",
              adapter.parseFocusResult(output: "not even a real reply", session: sessionArg, tabID: "t"))
    }
}

/// Assembles a `focusScript` reply: the two `zmx list` dumps a real switch
/// attempt produces, framed exactly as `focusScript` frames them.
func focusResponse(before: [String], after: [String]) -> String {
    var out = MuxScript.begin("focus") + "\n"
    out += MuxScript.topology("focus") + "\n"
    out += "::MX_FOCUS_BEFORE::\n"
    for r in before { out += r + "\n" }
    out += "::MX_FOCUS_AFTER::\n"
    for r in after { out += r + "\n" }
    out += MuxScript.end("focus") + "\n"
    return out
}

print("\n== 9. parseFocusResult: a clean single-client transfer confirms ==")
do {
    let out = focusResponse(
        before: [row("cur", pid: 1, clients: 1), row("tgt", pid: 2, clients: 0)],
        after: [row("cur", pid: 1, clients: 0), row("tgt", pid: 2, clients: 1)]
    )
    check("reports success", adapter.parseFocusResult(output: out, session: "cur", tabID: "tgt"))
}

print("\n== 10. parseFocusResult: DEFECT 2's exact repro -- ZMX_SESSION names a session with no client ==")
do {
    // `session` (what the app believes is the pane's current home) exists
    // but has zero clients -- the wrong-session-name bug this whole
    // mechanism exists to catch. `switchSesh`'s fire-and-forget IPC still
    // exits 0 with the target completely unaffected.
    let out = focusResponse(
        before: [row("cur", pid: 1, clients: 0), row("tgt", pid: 2, clients: 0)],
        after: [row("cur", pid: 1, clients: 0), row("tgt", pid: 2, clients: 0)]
    )
    check("does NOT report success (the old bug recorded this as one)",
          !adapter.parseFocusResult(output: out, session: "cur", tabID: "tgt"))
}

print("\n== 11. parseFocusResult: rc=0 but nothing actually moved (session DID have a client) ==")
do {
    // The other way a fire-and-forget switch can no-op: `session` genuinely
    // had a leader, but the daemon-side forward silently failed to land
    // (wedged client, dropped message) and neither count budges.
    let out = focusResponse(
        before: [row("cur", pid: 1, clients: 1), row("tgt", pid: 2, clients: 0)],
        after: [row("cur", pid: 1, clients: 1), row("tgt", pid: 2, clients: 0)]
    )
    check("does NOT report success", !adapter.parseFocusResult(output: out, session: "cur", tabID: "tgt"))
}

print("\n== 12. parseFocusResult: a session shared by two panes is not mistaken for failure ==")
do {
    // `session` had 2 clients (two panes attached to it, entirely ordinary --
    // see the badge these same counts drive); one of them switched away,
    // leaving 1, not 0. A check that assumed "must reach exactly zero" or
    // "must have started at exactly one" would wrongly call this a failure.
    let out = focusResponse(
        before: [row("cur", pid: 1, clients: 2), row("tgt", pid: 2, clients: 0)],
        after: [row("cur", pid: 1, clients: 1), row("tgt", pid: 2, clients: 1)]
    )
    check("reports success", adapter.parseFocusResult(output: out, session: "cur", tabID: "tgt"))
}

print("\n== 13. parseFocusResult: only one side moved -- coincidence, not this switch ==")
do {
    // tgt gained a client but cur lost none: some unrelated pane attached to
    // tgt during the poll window, not evidence THIS switch landed.
    let onlyTargetGained = focusResponse(
        before: [row("cur", pid: 1, clients: 1), row("tgt", pid: 2, clients: 0)],
        after: [row("cur", pid: 1, clients: 1), row("tgt", pid: 2, clients: 1)]
    )
    check("target-only change does not confirm",
          !adapter.parseFocusResult(output: onlyTargetGained, session: "cur", tabID: "tgt"))
    // cur lost a client but tgt gained none: that client detached outright,
    // it did not switch to tgt.
    let onlySourceLost = focusResponse(
        before: [row("cur", pid: 1, clients: 1), row("tgt", pid: 2, clients: 0)],
        after: [row("cur", pid: 1, clients: 0), row("tgt", pid: 2, clients: 0)]
    )
    check("source-only change does not confirm",
          !adapter.parseFocusResult(output: onlySourceLost, session: "cur", tabID: "tgt"))
}

print("\n== 14. parseFocusResult: a truncated or malformed reply never confirms ==")
do {
    check("no begin/end markers at all",
          !adapter.parseFocusResult(output: "garbage", session: "cur", tabID: "tgt"))
    let noAfter = MuxScript.begin("focus") + "\n" + MuxScript.topology("focus") + "\n"
        + "::MX_FOCUS_BEFORE::\n" + row("cur", pid: 1, clients: 1) + "\n"
        + MuxScript.end("focus") + "\n"
    check("before-listing present but after-listing missing (mid-poll truncation)",
          !adapter.parseFocusResult(output: noAfter, session: "cur", tabID: "tgt"))
    let missingTargetRow = focusResponse(
        before: [row("cur", pid: 1, clients: 1)],
        after: [row("cur", pid: 1, clients: 0)]
    )
    check("tgt never listed in either dump", !adapter.parseFocusResult(output: missingTargetRow, session: "cur", tabID: "tgt"))
}

print("\n== 15. v0.7.0 start_dir row still parses ==")
do {
    let out = response(rows: ["  name=old\(TAB)pid=9\(TAB)clients=1\(TAB)created=\(Int(Date().timeIntervalSince1970))\(TAB)start_dir=/home/tester"],
                       captures: [])
    let r = adapter.parseTick(output: out, session: "old", nonce: n)
    check("v0.7.0 row becomes a tab", r?.snapshot.tabs.map(\.id) == ["old"], "got \(String(describing: r?.snapshot.tabs.map(\.id)))")
}

print("\n== 16. tickScript shape ==")
do {
    let s = adapter.tickScript(session: "cur", request: MuxTickRequest(fetch: ["a","b"]), nonce: n)
    check("guards on zmx presence", s.contains("command -v zmx"))
    check("emits ::SESSIONS:: for the shared parser", s.contains("::SESSIONS::"))
    check("lists sessions", s.contains("zmx list"))
    check("captures each fetched session", s.components(separatedBy: "zmx history").count == 3, "history occurrences=\(s.components(separatedBy: "zmx history").count - 1)")
    check("tails the capture", s.contains("tail -n"))
    check("does NOT export ZMX_SESSION on the listing", !s.contains("ZMX_SESSION=\"cur\""))
    // `zmx history --vt` ends mid-line on a cursor-position escape rather than
    // a newline, so without a terminator the NEXT pane marker is echoed onto
    // that same line and `MuxScript.sections` -- which matches markers with
    // `hasPrefix` on whole lines -- stops seeing it. Every session after the
    // first then loses its frame and its exposé cell stays a placeholder.
    check("terminates each capture so the next marker starts a line",
          s.components(separatedBy: "tail -n \(80); echo").count == 3,
          "terminated captures=\(s.components(separatedBy: "tail -n \(80); echo").count - 1)")
}

print("\n== 17. an unterminated capture swallows the next marker ==")
do {
    // Characterises WHY check 10 requires the terminator. Built by hand: the
    // `response` helper appends "\n" to every body, which is exactly the
    // assumption that hid this against a real host.
    var out = MuxScript.begin(n) + "\n"
    out += MuxScript.topology(n) + "\n"
    out += "::SESSIONS::\n"
    out += row("alpha", pid: 1, clients: 1) + "\n"
    out += row("beta", pid: 2, clients: 0) + "\n"
    out += "::MX_P_\(n):alpha:::\n"
    out += "alpha screen\u{1B}[4;1H"            // no newline, as zmx really emits
    out += "::MX_P_\(n):beta:::\n"             // glued onto the line above
    out += "beta screen\u{1B}[4;1H"
    out += "\n" + MuxScript.end(n) + "\n"
    let r = adapter.parseTick(output: out, session: "alpha", nonce: n)
    check("beta gets no frame when the marker is glued", r?.frames["beta"] == nil)

    // The same bytes with the terminator the script now emits.
    var fixed = MuxScript.begin(n) + "\n"
    fixed += MuxScript.topology(n) + "\n"
    fixed += "::SESSIONS::\n"
    fixed += row("alpha", pid: 1, clients: 1) + "\n"
    fixed += row("beta", pid: 2, clients: 0) + "\n"
    fixed += "::MX_P_\(n):alpha:::\n"
    fixed += "alpha screen\u{1B}[4;1H" + "\n"
    fixed += "::MX_P_\(n):beta:::\n"
    fixed += "beta screen\u{1B}[4;1H" + "\n"
    fixed += MuxScript.end(n) + "\n"
    let f = adapter.parseTick(output: fixed, session: "alpha", nonce: n)
    check("both sessions get frames once terminated",
          f?.frames["alpha"] != nil && f?.frames["beta"] != nil,
          "alpha=\(f?.frames["alpha"] != nil) beta=\(f?.frames["beta"] != nil)")
}

print("\n== 18. a row wider than the old 100-column constant is not wrapped ==")
do {
    // Real dump shape: rows joined by `\r\n`, the last one unterminated
    // (zmx ends mid-line on a cursor-position escape) -- `response()`'s own
    // trailing "\n" stands in for the script's `; echo` terminator, exactly
    // as it does against a real host. Not built with `response`'s bare-`\n`
    // convenience: that hid the bug check 11 characterises.
    let wide = String(repeating: "A", count: 137)
    let short = String(repeating: "B", count: 60)
    let body = wide + "\r\n" + short
    let out = response(rows: [row("wide137", pid: 1, clients: 1)], captures: [("wide137", body)])
    guard let r = adapter.parseTick(output: out, session: "wide137", nonce: n) else {
        failures += 1; print("  FAIL  nil"); exit(1)
    }
    let tab = r.snapshot.tabs.first { $0.id == "wide137" }
    check("cols >= widest row (137)", (tab?.cols ?? 0) >= 137, "got \(String(describing: tab?.cols))")
    check("the old 100-column constant would have wrapped this", (tab?.cols ?? 0) > 100, "got \(String(describing: tab?.cols))")
    check("rect width matches the tab's cols", tab?.panes.first?.rect.width == tab?.cols)
}

print("\n== 19. ANSI/SGR escapes do not inflate measured width ==")
do {
    // 40 SGR sequences (400 raw bytes, 0 visible cells) around 2 visible
    // characters. If stripping failed the raw byte count alone would blow
    // past the 80-column floor.
    let sgrJunk = String(repeating: "\u{1B}[38;5;200m", count: 40)
    let body = sgrJunk + "hi" + "\u{1B}[0m"
    let out = response(rows: [row("sgrheavy", pid: 1, clients: 1)], captures: [("sgrheavy", body)])
    guard let r = adapter.parseTick(output: out, session: "sgrheavy", nonce: n) else {
        failures += 1; print("  FAIL  nil"); exit(1)
    }
    let tab = r.snapshot.tabs.first { $0.id == "sgrheavy" }
    check("floors to 80 despite 400+ raw bytes of SGR", tab?.cols == 80, "got \(String(describing: tab?.cols))")
}

print("\n== 20. no fresh capture this tick keeps the cached geometry ==")
do {
    let wide = String(repeating: "C", count: 137) + "\r\n" + String(repeating: "D", count: 60)
    let out1 = response(rows: [row("sticky", pid: 1, clients: 1)], captures: [("sticky", wide)])
    guard let r1 = adapter.parseTick(output: out1, session: "sticky", nonce: n) else {
        failures += 1; print("  FAIL  nil"); exit(1)
    }
    let firstTab = r1.snapshot.tabs.first { $0.id == "sticky" }
    let firstCols = firstTab?.cols
    let firstRows = firstTab?.rows
    check("first tick measures the wide capture", (firstCols ?? 0) >= 137, "got \(String(describing: firstCols))")

    // Second tick: "sticky" is still listed (zmx list still reports it) but
    // not fetched -- as if it were a hidden cell, fetched only every third
    // tick.
    let out2 = response(rows: [row("sticky", pid: 1, clients: 1)], captures: [])
    guard let r2 = adapter.parseTick(output: out2, session: "sticky", nonce: n) else {
        failures += 1; print("  FAIL  nil"); exit(1)
    }
    let secondTab = r2.snapshot.tabs.first { $0.id == "sticky" }
    let secondCols = secondTab?.cols
    let secondRows = secondTab?.rows
    check("no fresh capture: cols unchanged from the cache", secondCols == firstCols,
          "first=\(String(describing: firstCols)) second=\(String(describing: secondCols))")
    check("no fresh capture: rows unchanged from the cache", secondRows == firstRows,
          "first=\(String(describing: firstRows)) second=\(String(describing: secondRows))")
    check("does not collapse to the 120x24 no-capture-yet fallback",
          !(secondCols == 120 && secondRows == 24), "got \(String(describing: secondCols))x\(String(describing: secondRows))")
}

print("\n== 21. sliding window follows a real shrink down, but not on one narrow frame ==")
do {
    let wideRow = String(repeating: "E", count: 200)
    let narrowRow = String(repeating: "F", count: 90)
    func tickCols(_ body: String) -> Int? {
        let out = response(rows: [row("shrinker", pid: 1, clients: 1)], captures: [("shrinker", body)])
        let r = adapter.parseTick(output: out, session: "shrinker", nonce: n)
        return r?.snapshot.tabs.first { $0.id == "shrinker" }?.cols
    }
    let afterWide = tickCols(wideRow)
    check("initial wide observation quantizes to 208", afterWide == 208, "got \(String(describing: afterWide))")
    let afterOneNarrow = tickCols(narrowRow)
    check("a single narrow frame does not shrink it yet", afterOneNarrow == 208, "got \(String(describing: afterOneNarrow))")
    var afterThreeNarrow: Int?
    for _ in 0..<2 { afterThreeNarrow = tickCols(narrowRow) }
    check("still holding the old high while it remains in the window", afterThreeNarrow == 208, "got \(String(describing: afterThreeNarrow))")
    let afterFourNarrow = tickCols(narrowRow)
    check("genuine resize down wins once the old high rolls off (4th narrow observation)",
          afterFourNarrow == 96, "got \(String(describing: afterFourNarrow))")
}

print("\n== 22. zmx's fork-not-exec pair collapses to one binding instead of declining ==")
do {
    // `zmx a foo1` forks its session daemon as a child of the attaching
    // client rather than exec'ing into it, so `detect()` sees TWO related
    // candidates for one hand-typed attach -- the client and its fork --
    // that both resolve the same socket and so carry an identical binding.
    // That is corroboration, not ambiguity. (id=zmx-fork-collapse)
    let client = FakeBinding(type: .zmx, sessionName: "foo1", hasOwnedAltScreen: false)
    let fork = FakeBinding(type: .zmx, sessionName: "foo1", hasOwnedAltScreen: false)
    let winner = collapseAgreeingBindings([client, fork])
    check("agreeing pair collapses to a binding", winner != nil)
    check("collapsed binding matches both candidates", winner == client, "got \(String(describing: winner))")
}

print("\n== 23. two related candidates naming DIFFERENT sessions still decline ==")
do {
    // The guard this collapse must preserve: genuine disagreement (two
    // different zmx sessions on the same connection) is still ambiguous and
    // must not guess.
    let foo1 = FakeBinding(type: .zmx, sessionName: "foo1", hasOwnedAltScreen: false)
    let foo2 = FakeBinding(type: .zmx, sessionName: "foo2", hasOwnedAltScreen: false)
    check("disagreeing pair declines", collapseAgreeingBindings([foo1, foo2]) == nil)
}

print("\n== 24. collapseAgreeingBindings edge cases ==")
do {
    check("empty list declines", collapseAgreeingBindings([FakeBinding]()) == nil)
    let one = FakeBinding(type: .tmux, sessionName: "work", hasOwnedAltScreen: true)
    check("single candidate is its own winner", collapseAgreeingBindings([one]) == one)
    let other = FakeBinding(type: .zellij, sessionName: "work", hasOwnedAltScreen: true)
    check("same session name but different type still declines", collapseAgreeingBindings([one, other]) == nil)
}

print("\n== 25. screen-state gate admits a passthrough on either screen ==")
do {
    // The regression: zmx is a transparent PTY passthrough, so its pane sits
    // on the ALTERNATE screen whenever anything full-screen runs inside the
    // session (helix, htop, vim, a pager). The gate used to require
    // `ownsAlternateScreen == altActive`, which made every one of those panes
    // undetectable and fell back to the app's own tabs.
    // (id=zmx-passthrough-detect)
    check("passthrough admitted at a bare prompt",
          MuxScreenGate.admits(ownsAlternateScreen: false, alternateScreenActive: false))
    check("passthrough admitted under a full-screen TUI",
          MuxScreenGate.admits(ownsAlternateScreen: false, alternateScreenActive: true))
}

print("\n== 26. screen-state gate still rejects a non-attached alt-screen owner ==")
do {
    // The guard that must survive: tmux/zellij/herdr hold the alternate
    // screen for the whole attach, so one seen on a PRIMARY screen is a bare
    // `tmux ls`, not an attach. Unchanged in both directions.
    check("alt-screen owner admitted while alternate is active",
          MuxScreenGate.admits(ownsAlternateScreen: true, alternateScreenActive: true))
    check("alt-screen owner rejected at a bare prompt",
          !MuxScreenGate.admits(ownsAlternateScreen: true, alternateScreenActive: false))
}

print("\n== 27. a switch is declined on a session more than one client holds ==")
do {
    // The regression (BUG 4): zmx forwards `.Switch` to the session's LEADER
    // client, which on a shared session is as likely to be some OTHER
    // terminal as it is to be this pane. That terminal moves, this pane does
    // not, and `parseFocusResult` cannot tell the difference because the
    // aggregate `clients=` counts shift identically either way -- so the tab
    // got renamed to a session it was never switched to.
    // (id=zmx-focus-leader-guard)
    let a27 = ZmxExposeAdapter()
    check("no listing seen yet: cannot claim a second client, so allowed",
          a27.canFocus(session: "alpha", tabID: "beta"))

    let shared = response(
        rows: [row("alpha", pid: 1, clients: 2),
               row("beta", pid: 2, clients: 1),
               row("solo", pid: 3, clients: 1)],
        captures: [("alpha", "screen")])
    _ = a27.parseTick(output: shared, session: "alpha", nonce: n)

    check("declines while the CURRENT session has two clients",
          !a27.canFocus(session: "alpha", tabID: "beta"))
    check("allows from a session only this pane holds",
          a27.canFocus(session: "solo", tabID: "beta"))
    check("the TARGET's client count is irrelevant",
          a27.canFocus(session: "solo", tabID: "alpha"))
    check("a no-op reselect of the current cell is never declined",
          a27.canFocus(session: "alpha", tabID: "alpha"))
    check("no current session to leave is never declined",
          a27.canFocus(session: nil, tabID: "beta"))
    check("empty current session is never declined",
          a27.canFocus(session: "", tabID: "beta"))

    // Following a real detach: the same adapter must stop declining once the
    // listing says the second client has gone, or the guard would latch.
    let freed = response(
        rows: [row("alpha", pid: 1, clients: 1),
               row("beta", pid: 2, clients: 1)],
        captures: [("alpha", "screen")])
    _ = a27.parseTick(output: freed, session: "alpha", nonce: n)
    check("stops declining once the second client detaches",
          a27.canFocus(session: "alpha", tabID: "beta"))
}

print("\n== 28. a capture the tail cap cut is not measured ==")
do {
    // The regression (BUG 1): `zmx history --vt` normally carries no
    // erase-display at all, so `visibleScreen` returns the whole `tail -n 80`
    // window. While the dump is shorter than the window that IS the screen and
    // measuring it is right. Once the dump is longer, the rows that come back
    // are scrollback, the row count is just the cap, and the widest row is
    // whatever some old line needed. A real 200x50 session with plain scrolled
    // output measured 20x80 that way -- wrong on both axes.
    // (id=zmx-capture-cap-truncation)
    let a28 = ZmxExposeAdapter()
    let narrow = (1...80).map { "line \($0)" }.joined(separator: "\n")
    let capped = response(rows: [row("big", pid: 1, clients: 1)], captures: [("big", narrow)])
    guard let rc = a28.parseTick(output: capped, session: "big", nonce: n) else {
        failures += 1; print("  FAIL  parseTick returned nil"); exit(1)
    }
    check("cap-filling capture falls back rather than claiming 80 rows",
          rc.snapshot.tabs[0].rows == 24 && rc.snapshot.tabs[0].cols == 120,
          "got \(rc.snapshot.tabs[0].cols)x\(rc.snapshot.tabs[0].rows)")
    check("still delivers the frame it captured",
          rc.frames["big"] != nil)

    // The working case must keep working: a dump shorter than the window is a
    // whole screen, and its height is the session's height.
    let a28b = ZmxExposeAdapter()
    let screen = (1...38).map { _ in String(repeating: "x", count: 144) }.joined(separator: "\n")
    let whole = response(rows: [row("hx", pid: 1, clients: 1)], captures: [("hx", screen)])
    guard let rw = a28b.parseTick(output: whole, session: "hx", nonce: n) else {
        failures += 1; print("  FAIL  parseTick returned nil"); exit(1)
    }
    check("an uncut screen is still measured (144x38 -> quantized)",
          rw.snapshot.tabs[0].cols >= 144 && rw.snapshot.tabs[0].rows >= 38,
          "got \(rw.snapshot.tabs[0].cols)x\(rw.snapshot.tabs[0].rows)")
    check("and is not inflated to the cap",
          rw.snapshot.tabs[0].rows < 80, "got \(rw.snapshot.tabs[0].rows)")

    // Primary-screen history can be shorter than the cap and still contain
    // scrollback. zmx ends its VT replay with the cursor restore, so use that
    // row rather than mistaking all 70 history rows for a 70-row terminal.
    let a28c = ZmxExposeAdapter()
    let scrollback = (1...70).map { "prompt \($0)" }.joined(separator: "\n")
        + "\u{1B}[38;3H"
    let primary = response(rows: [row("solo-b", pid: 1, clients: 1)],
                           captures: [("solo-b", scrollback)])
    guard let rp = a28c.parseTick(output: primary, session: "solo-b", nonce: n) else {
        failures += 1; print("  FAIL  primary-screen parseTick returned nil"); exit(1)
    }
    check("primary-screen cursor restore wins over short scrollback height",
          rp.snapshot.tabs[0].rows == 40,
          "got \(rp.snapshot.tabs[0].cols)x\(rp.snapshot.tabs[0].rows)")

    let state = ZmxExposeAdapter.restoredTerminalState("\u{1B}[?1049h\u{1B}[28;7H")
    check("restored terminal state recognises alternate screen and cursor row",
          state.alternateScreen && state.cursorRow == 28,
          "got alternate=\(state.alternateScreen) row=\(String(describing: state.cursorRow))")
}

print("\n== 29. detach-switch gate: a shell is there only with no configured takeover ==")
do {
    // The redesign this harness now has to cover (id=zmx-detach-switch):
    // `MultiplexerExposeFeed.focus` may switch a zmx pane by detaching
    // (ctrl+\) and retyping the attach command instead of routing through
    // the leader-addressed IPC Group 27 guards, but only where that is
    // known safe. `MuxDetachGate.hasFallbackShell` is the rule -- restated
    // here as the plain predicate `SSHConfig.hasExecTakeoverCommand` wraps,
    // since that real type is not linked into this harness (GhosttyKit,
    // NIOSSH). Every one of the five inputs on its own must be enough to
    // withdraw the claim: any of them means the pane's own channel command
    // may have replaced the shell, exactly the case that would turn a
    // ctrl+\ detach into ending the whole pane.
    check("a plain interactive shell has one to fall back to",
          MuxDetachGate.hasFallbackShell(
              hasRemoteCommand: false, hasInitialCommandLaunch: false,
              tmuxAutoEnable: false, herdrAutoEnable: false, zmxAutoEnable: false))
    check("an explicit remote command withdraws it",
          !MuxDetachGate.hasFallbackShell(
              hasRemoteCommand: true, hasInitialCommandLaunch: false,
              tmuxAutoEnable: false, herdrAutoEnable: false, zmxAutoEnable: false))
    check("an initial-command-with-PTY launch withdraws it",
          !MuxDetachGate.hasFallbackShell(
              hasRemoteCommand: false, hasInitialCommandLaunch: true,
              tmuxAutoEnable: false, herdrAutoEnable: false, zmxAutoEnable: false))
    check("tmux auto-start withdraws it",
          !MuxDetachGate.hasFallbackShell(
              hasRemoteCommand: false, hasInitialCommandLaunch: false,
              tmuxAutoEnable: true, herdrAutoEnable: false, zmxAutoEnable: false))
    check("herdr auto-start withdraws it",
          !MuxDetachGate.hasFallbackShell(
              hasRemoteCommand: false, hasInitialCommandLaunch: false,
              tmuxAutoEnable: false, herdrAutoEnable: true, zmxAutoEnable: false))
    check("zmx auto-start withdraws it -- SSHConfig.zmxExecCommandLine's own `exec`",
          !MuxDetachGate.hasFallbackShell(
              hasRemoteCommand: false, hasInitialCommandLaunch: false,
              tmuxAutoEnable: false, herdrAutoEnable: false, zmxAutoEnable: true))
    check("more than one configured takeover still withdraws it",
          !MuxDetachGate.hasFallbackShell(
              hasRemoteCommand: true, hasInitialCommandLaunch: true,
              tmuxAutoEnable: false, herdrAutoEnable: false, zmxAutoEnable: true))
}

print("\n== 30. consumesCommandEcho / suppressesTitleUpdate ==")
do {
    // The real 134-character command rootshell types to attach: the exact
    // fixture the regressions below are stated against.
    let fullCommand = "sh -c 'PATH=\"$PATH:/usr/local/bin:/opt/homebrew/bin:/home/linuxbrew/.linuxbrew/bin:/snap/bin\" ZMX_SESSION_PREFIX= zmx attach \"solo-a\"'"
    check("fixture is the real 134-character attach command", fullCommand.count == 134, "got \(fullCommand.count)")

    func armed(_ command: String = fullCommand, until: Date = Date().addingTimeInterval(2)) -> FakeTitleTarget {
        let t = FakeTitleTarget()
        t.pendingCommandEcho = (command: command, until: until)
        return t
    }

    // REGRESSION, the important one: the old rule tested containment in
    // EITHER direction, and `zmx attach "solo-a"` contains the session name
    // "solo-a" -- so the old rule swallowed the one title actually worth
    // keeping: "solo-a" is exactly the correct title zmx replays out of the
    // session it just attached to. Eating it was the bug.
    do {
        let t = armed()
        check("REGRESSION: zmx's own replayed session title is not eaten",
              !t.consumesCommandEcho("solo-a"))
    }

    // REGRESSION: fish truncates the command to 20 characters
    // (`string sub -l 20` in `__fish_default_title`) and then appends a
    // shortened pwd, so what fish actually reports matches neither a prefix
    // nor a superstring test. The old containment rule matched this in
    // neither direction, which is why the echoed title stuck.
    let fishTitle = "sh -c 'PATH=\"$PATH:/ ~/project"
    do {
        let t = armed()
        check("REGRESSION: fish's real reported title is swallowed",
              t.consumesCommandEcho(fishTitle))
    }

    // fish over SSH additionally prepends a bracketed host; must also be
    // swallowed.
    let fishSSHTitle = "[fixture-host] sh -c 'PATH=\"$PATH:/ ~/project"
    do {
        let t = armed()
        check("fish-over-SSH title (bracketed host prefix) is swallowed",
              t.consumesCommandEcho(fishSSHTitle))
    }

    // bash/zsh report the command verbatim -- must be swallowed too.
    do {
        let t = armed()
        check("bash/zsh verbatim echo is swallowed",
              t.consumesCommandEcho(fullCommand))
    }

    // One-shot: after a successful swallow, a second call with the same
    // title returns false -- the filter disarmed.
    do {
        let t = armed()
        check("first call swallows", t.consumesCommandEcho(fullCommand))
        check("one-shot: second call with the same title does not swallow",
              !t.consumesCommandEcho(fullCommand))
    }

    // An unrelated genuine title must sail through untouched.
    do {
        let t = armed()
        check("unrelated genuine title (htop) is not swallowed",
              !t.consumesCommandEcho("htop"))
    }

    // The post-detach prompt title on its own is handled by the SUPPRESSION
    // window (titleSuppressedUntil / suppressesTitleUpdate), not by this
    // one-shot echo filter -- pinning the division of responsibility.
    do {
        let t = armed()
        check("post-detach prompt title alone is not swallowed by the echo filter",
              !t.consumesCommandEcho("~/project"))
    }

    // Expiry: an echo armed with `until` already in the past returns false
    // and disarms.
    do {
        let t = armed(until: Date().addingTimeInterval(-1))
        check("expired echo does not swallow", !t.consumesCommandEcho(fullCommand))
        check("expired echo disarms", t.pendingCommandEcho == nil)
    }

    // Short-command path: when the command is shorter than
    // commandEchoMatchPrefix (16), the leading-slice test is skipped
    // entirely and only an exact report matches.
    do {
        let shortCommand = "echo hi"
        check("short command is indeed under the match prefix",
              shortCommand.count < FakeTitleTarget.commandEchoMatchPrefix, "len=\(shortCommand.count)")
        let exact = armed(shortCommand)
        check("short command: exact match swallows",
              exact.consumesCommandEcho(shortCommand))
        let nearMiss = armed(shortCommand)
        check("short command: near-miss substring does NOT swallow",
              !nearMiss.consumesCommandEcho("echo hi there"))
    }

    // suppressesTitleUpdate(): true while titleSuppressedUntil is in the
    // future, false (and self-clearing to nil) once it is in the past, and
    // false outright when nil.
    do {
        let future = FakeTitleTarget()
        future.titleSuppressedUntil = Date().addingTimeInterval(2)
        check("suppresses while in the future", future.suppressesTitleUpdate())

        let past = FakeTitleTarget()
        past.titleSuppressedUntil = Date().addingTimeInterval(-1)
        check("does not suppress once in the past", !past.suppressesTitleUpdate())
        check("self-clears to nil once lapsed", past.titleSuppressedUntil == nil)

        let none = FakeTitleTarget()
        check("does not suppress when nil", !none.suppressesTitleUpdate())
    }
}

print("\n== 31. never-attached sparse captures keep zmx's fallback width ==")
do {
    let a31 = ZmxExposeAdapter()
    let sparse = "quiet agent\nready> "
    let out = response(
        rows: [row("never", pid: 1, clients: 0),
               row("attached", pid: 2, clients: 1)],
        captures: [("never", sparse), ("attached", sparse)])
    guard let r = a31.parseTick(output: out, session: "attached", nonce: n) else {
        failures += 1; print("  FAIL  parseTick returned nil"); exit(1)
    }
    let never = r.snapshot.tabs.first { $0.id == "never" }
    let attached = r.snapshot.tabs.first { $0.id == "attached" }
    check("clients=0 sparse capture stays at zmx's 120-column fallback",
          never?.cols == 120, "got \(String(describing: never?.cols))")
    check("attached sparse capture retains the ordinary 80-column floor",
          attached?.cols == 80, "got \(String(describing: attached?.cols))")
}

print("\n== 32. detach-switch census distinguishes complete and half switches ==")
do {
    check("one client moves from source to target: confirmed",
          MuxZmxDetachTransfer.classify(
              sourceBefore: 1, targetBefore: 0, sourceAfter: 0, targetAfter: 1
          ) == .confirmed)
    check("no count changes: safe full retry",
          MuxZmxDetachTransfer.classify(
              sourceBefore: 1, targetBefore: 0, sourceAfter: 1, targetAfter: 0
          ) == .unchanged)
    check("single source detached but attach was dropped: attach-only retry",
          MuxZmxDetachTransfer.classify(
              sourceBefore: 1, targetBefore: 0, sourceAfter: 0, targetAfter: 0
          ) == .detachedOnly)
    check("multi-client source decrease without target increase is ambiguous",
          MuxZmxDetachTransfer.classify(
              sourceBefore: 2, targetBefore: 0, sourceAfter: 1, targetAfter: 0
          ) == .ambiguous)
    check("unrelated target movement is ambiguous",
          MuxZmxDetachTransfer.classify(
              sourceBefore: 1, targetBefore: 0, sourceAfter: 1, targetAfter: 1
          ) == .ambiguous)
}

print("\n\(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")")
exit(failures == 0 ? 0 : 1)
