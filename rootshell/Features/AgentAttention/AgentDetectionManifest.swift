//
//  AgentDetectionManifest.swift
//  rootshell
//
//  Data-driven agent detection: a small rules VM ported from herdr's
//  manifest engine. Rules match regions of a detection snapshot with
//  contains / regex / lineRegex matchers composed through all / any / not
//  gates; the highest-priority match wins (file order breaks ties).
//
//  The hand-maintained manifest ships embedded in the binary
//  (AgentDetectionManifestData) so bundle packaging can never silently
//  drop it. A JSON file named `AgentDetectionRules.json` in the
//  app's Documents folder overrides the bundled manifest for field
//  debugging of rules.
//
//  Forward-tolerant loading: unknown fields are ignored; a rule with an
//  invalid regex, unknown state, or unknown region is dropped with a log,
//  never a crash. Matching is strictly read-only over hostile text.
//
//  Not Sendable (compiled Regex payloads are used from one actor only):
//  `bundled` is MainActor-isolated and the attention center only touches
//  it there.
//

import Foundation
import os.log

nonisolated struct AgentDetectionManifest {

    // MARK: - Compiled types

    /// One region, in the three forms the matchers need. `flat` is
    /// `lower` with every run of whitespace — newlines included —
    /// collapsed to a single space, which is what makes `contains`
    /// survive line wrapping: a TUI soft-wraps its footer at a word
    /// boundary ("… Esc to" / "cancel"), and a needle spanning that break
    /// is otherwise invisible. Wrapping is width-dependent, so without
    /// this a rule works on a wide terminal and silently stops matching
    /// on a narrow one.
    nonisolated struct RegionText {
        let text: String
        let lower: String
        let flat: String

        init(_ text: String) {
            self.text = text
            let lower = text.lowercased()
            self.lower = lower
            self.flat = lower.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    /// One matcher gate. Every
    /// `contains` needle must appear (case-insensitive); every `regex`
    /// must match the region; every `lineRegex` must match at least one
    /// line; all `all` gates must match; at least one `any` gate must
    /// match when `any` is non-empty; no `not` gate may match.
    nonisolated struct Gate {
        var contains: [String] = []           // pre-lowercased at compile
        var regex: [Regex<AnyRegexOutput>] = []
        var lineRegex: [Regex<AnyRegexOutput>] = []
        var all: [Gate] = []
        var any: [Gate] = []
        var not: [Gate] = []

        func matches(_ region: RegionText) -> Bool {
            // Wrap-tolerant: needles match the whitespace-collapsed form.
            // Anchored patterns keep the raw text — line anchors and (?m)
            // must still see real rows.
            for needle in contains where !region.flat.contains(needle) { return false }
            for pattern in regex where !Self.firstMatch(pattern, in: region.text) { return false }
            for pattern in lineRegex {
                let lines = region.text.split(separator: "\n", omittingEmptySubsequences: false)
                guard lines.contains(where: { Self.firstMatch(pattern, in: String($0)) }) else {
                    return false
                }
            }
            for gate in all where !gate.matches(region) { return false }
            if !any.isEmpty, !any.contains(where: { $0.matches(region) }) {
                return false
            }
            for gate in not where gate.matches(region) { return false }
            return true
        }

        private static func firstMatch(_ pattern: Regex<AnyRegexOutput>, in text: String) -> Bool {
            ((try? pattern.firstMatch(in: text)) ?? nil) != nil
        }

        /// A gate (or one of its descendants) must carry at least one
        /// positive matcher to be meaningful.
        var hasPositiveMatcher: Bool {
            !contains.isEmpty || !regex.isEmpty || !lineRegex.isEmpty
                || all.contains(where: \.hasPositiveMatcher)
                || any.contains(where: \.hasPositiveMatcher)
        }
    }

    nonisolated struct Rule {
        var id: String
        var state: AgentScreenState
        var priority: Int
        var region: String
        var visibleIdle: Bool
        var visibleBlocker: Bool
        var visibleWorking: Bool
        var skipStateUpdate: Bool
        var gate: Gate
    }

    /// An identity signature: a gate plus an evidence grade. Weak
    /// (banner-name) signatures may IDENTIFY an agent — missing a launch
    /// is worse than a transient false positive — but they cannot keep
    /// one alive on the primary screen: after exit the name is just
    /// scrollback text, and pinning identity to it is how "stuck showing
    /// OpenCode" happened. On the alt screen the TUI owns the content,
    /// so weak evidence counts there.
    nonisolated struct Signature {
        var gate: Gate
        var weak: Bool
        /// Stricter than `weak`: counts for nothing, not even
        /// identification, unless the alt screen is owned. For an agent
        /// whose only signature is its bare product name AND that runs
        /// full-screen: the name in ordinary shell output (a `ccusage`
        /// table, a README, a `brew list`) must not mint a phantom
        /// session. Verified per agent by launching it in a pty and
        /// checking for `ESC[?1049h` — opencode and copilot take the alt
        /// screen; codex, gemini and cursor-agent render inline, so their
        /// name signatures cannot be tightened this way.
        var requiresAltScreen: Bool
        /// Region the gate matches against; nil = the whole snapshot.
        /// Bottom-anchored regions are how live chrome (an agent's input
        /// box) states "this agent is on screen right now" — after exit
        /// a couple of shell lines push it out of the window, which
        /// scrollback-wide matching could never express.
        var region: String?
    }

    nonisolated struct Agent {
        var id: String
        var displayName: String
        /// agent = coding-agent entry (identity via signatures/titles,
        /// TUI-shaped presence rules); task = long-running command or
        /// prompt entry (identity IS a matching working/blocked rule).
        var kind: AttentionCategory = .agent
        /// Settings-toggle grouping; required (and always present) for
        /// task entries, nil for agents.
        var family: TaskFamily?
        /// Optional task progress extractor: first capture = percent, or
        /// two captures = current/total. Bottom-anchored region.
        var progressPattern: Regex<AnyRegexOutput>?
        var progressRegion: String?
        /// Exact command basenames (local-shell identity hint).
        var commands: Set<String>
        /// Identity-grade OSC title patterns, distinctive per agent.
        var titlePatterns: [Regex<AnyRegexOutput>]
        /// Identity-grade screen signatures; any applicable matching
        /// signature identifies the agent from the snapshot.
        var screenSignatures: [Signature]
        /// Classification rules, priority-descending, file order on ties.
        var rules: [Rule]
    }

    var snapshotRows: Int
    var agents: [Agent]
    /// Task entries (kind == .task), fully separate from the agent list:
    /// every existing agent API iterates `agents` only.
    var tasks: [Agent]
    private var byCommand: [String: Int]

    var agentCount: Int { agents.count }
    var taskCount: Int { tasks.count }
    var ruleCount: Int { agents.reduce(0) { $0 + $1.rules.count } }
    var isEmpty: Bool { agents.isEmpty && tasks.isEmpty }

    // MARK: - Identity

    /// Cheap identity from the OSC title alone (no screen read). Used on
    /// every title change.
    func identifyAgent(fromTitle title: String) -> Agent? {
        guard !title.isEmpty else { return nil }
        for agent in agents where !agent.titlePatterns.isEmpty {
            for pattern in agent.titlePatterns {
                if ((try? pattern.firstMatch(in: title)) ?? nil) != nil { return agent }
            }
        }
        return nil
    }

    /// Full identity pass: title patterns first, then screen signatures.
    ///
    /// ⛔ NEVER ADOPT AN IDENTITY YOU CANNOT HOLD. Weak (banner-name)
    /// signatures are refused here on the primary screen for exactly the
    /// reason `agentStillPresent` refuses them: if the only evidence is a
    /// product name in ordinary text, the next presence check fails and
    /// the pane is cleared — then re-identified from the same text, and
    /// cleared again. Field repro: a Claude session *discussing*
    /// Antigravity flapped into "Antigravity CLI" every three seconds,
    /// because "antigravity" was on screen and agy sorts first
    /// alphabetically. Identification and presence must use the same
    /// evidence bar or adoption is an infinite loop.
    ///
    /// Strong matches are also ranked ahead of weak ones so a visible
    /// agent's real chrome always beats another agent's name appearing in
    /// its output — alphabetical order must never decide that.
    func identifyAgent(from input: AgentDetectionInput) -> Agent? {
        if let byTitle = identifyAgent(fromTitle: input.oscTitle) { return byTitle }
        guard !input.screen.isEmpty else { return nil }
        var cache = RegionCache(input: input)
        var weakMatch: Agent?
        var best: (agent: Agent, matches: Int)?
        for agent in agents where !agent.screenSignatures.isEmpty {
            var strongMatches = 0
            for signature in agent.screenSignatures {
                let downgraded = signature.weak || signature.requiresAltScreen
                if downgraded, !input.altScreenIsAgentOwned { continue }
                let region = cache.text(for: signature.region)
                guard signature.gate.matches(region) else { continue }
                if downgraded {
                    if weakMatch == nil { weakMatch = agent }
                } else {
                    strongMatches += 1
                }
            }
            // Weight of evidence, not manifest order. An agent matching on
            // several independent pieces of chrome is on screen; one matching
            // a single phrase may just be being TALKED ABOUT. Returning the
            // first strong match let agy, which sorts first, take a claude
            // pane off one sentence while claude's prompt box and mode row
            // both matched right there on the same screen. Ties still fall to
            // file order, so nothing else about ranking changes.
            if strongMatches > 0, strongMatches > (best?.matches ?? 0) {
                best = (agent, strongMatches)
            }
        }
        return best?.agent ?? weakMatch
    }

    /// Presence pass for an already-identified agent: title evidence, or
    /// a signature that is strong or backed by alt-screen ownership.
    /// Weak banner text on the primary screen never counts.
    func agentStillPresent(_ agent: Agent, in input: AgentDetectionInput) -> Bool {
        if identifyAgent(fromTitle: input.oscTitle)?.id == agent.id { return true }
        guard !input.screen.isEmpty else { return false }
        var cache = RegionCache(input: input)
        for signature in agent.screenSignatures {
            if signature.weak || signature.requiresAltScreen, !input.altScreenIsAgentOwned { continue }
            let region = cache.text(for: signature.region)
            if signature.gate.matches(region) { return true }
        }
        return false
    }

    /// An agent OTHER than `held` that this snapshot identifies on strong
    /// evidence, when `held` has none of its own.
    ///
    /// This is how a pane changes hands without waiting out a no-signal
    /// streak. `agentStillPresent` and `definitivePresence` both answer
    /// "could this be the held agent?", and a classification rule keyed on
    /// a phrase two agents share ("esc to interrupt") answers yes for the
    /// wrong one — so a pane holding the wrong identity keeps proving
    /// itself present off the NEW agent's chrome. Field repro: a hand-typed
    /// zellij, claude in the first window, codex in the second, and the
    /// card still reading Claude Code.
    ///
    /// Strong evidence only, and refused outright rather than merely ranked
    /// lower. Weak (banner-name) and alt-gated signatures cannot take a
    /// pane: inside a multiplexer the alt screen belongs to the
    /// MULTIPLEXER, so every alt-gated signature would qualify and any pane
    /// whose output mentioned a product name would change hands. Taking a
    /// pane has to cost more than keeping one.
    func supersedingAgent(_ held: Agent, in input: AgentDetectionInput) -> Agent? {
        let byTitle = identifyAgent(fromTitle: input.oscTitle)
        if byTitle?.id == held.id { return nil }
        guard !input.screen.isEmpty else { return nil }
        var cache = RegionCache(input: input)
        guard !matchesStrongSignature(held, &cache) else { return nil }
        if let byTitle { return byTitle }
        // Weight of evidence here too, for the same reason: the agent that
        // matches on the most independent chrome is the one on screen.
        var best: (agent: Agent, matches: Int)?
        for candidate in agents where candidate.id != held.id {
            let matches = strongSignatureMatches(candidate, &cache)
            if matches > 0, matches > (best?.matches ?? 0) {
                best = (candidate, matches)
            }
        }
        return best?.agent
    }

    private func strongSignatureMatches(_ agent: Agent, _ cache: inout RegionCache) -> Int {
        var count = 0
        for signature in agent.screenSignatures
        where !signature.weak && !signature.requiresAltScreen {
            if signature.gate.matches(cache.text(for: signature.region)) { count += 1 }
        }
        return count
    }

    private func matchesStrongSignature(_ agent: Agent, _ cache: inout RegionCache) -> Bool {
        strongSignatureMatches(agent, &cache) > 0
    }

    /// Extracts + normalizes each region spec once per pass; regions
    /// repeat across signatures and rules. Internal so the center can
    /// share one cache across the task passes of a single scan.
    nonisolated struct RegionCache {
        let input: AgentDetectionInput
        private var whole: RegionText?
        private var byRegion: [String: RegionText] = [:]

        init(input: AgentDetectionInput) { self.input = input }

        mutating func text(for spec: String?) -> RegionText {
            guard let spec else {
                if let whole { return whole }
                let resolved = RegionText(input.screen)
                whole = resolved
                return resolved
            }
            if let cached = byRegion[spec] { return cached }
            let resolved = RegionText(AgentDetectionRegions.extract(spec, from: input))
            byRegion[spec] = resolved
            return resolved
        }
    }

    /// Exact command-name identity (local shell only).
    func agent(forCommand command: String) -> Agent? {
        guard let index = byCommand[command] else { return nil }
        return agents[index]
    }

    func agent(withID id: String) -> Agent? {
        agents.first(where: { $0.id == id })
    }

    // MARK: - Classification

    /// Classify an identified agent's pane from a snapshot. Rules run
    /// priority-descending, first match wins; no match falls back to
    /// `.idle` (strict-blocked bias: only explicit approval UI may map
    /// to blocked). `excludingOSCRegions` restricts to screen-chrome
    /// rules — used while a visible blocker is established, since titles
    /// keep animating through approval waits and must not clear blocked.
    func classify(
        agent: Agent,
        input: AgentDetectionInput,
        excludingOSCRegions: Bool = false
    ) -> AgentClassification {
        var cache = RegionCache(input: input)
        for rule in agent.rules {
            if excludingOSCRegions, rule.region == "osc_title" || rule.region == "osc_progress" {
                continue
            }
            let region = cache.text(for: rule.region)
            if rule.gate.matches(region) {
                return AgentClassification(
                    state: rule.state,
                    visibleIdle: rule.visibleIdle,
                    visibleBlocker: rule.visibleBlocker,
                    visibleWorking: rule.visibleWorking,
                    skipStateUpdate: rule.skipStateUpdate,
                    matchedRuleID: rule.id,
                    matchedRuleRegion: rule.region
                )
            }
        }
        return AgentClassification(state: .idle)
    }

    // MARK: - Task classification

    /// Classify a HELD task from a snapshot: all of its rules, priority
    /// descending, first match wins. nil when nothing matches — for a
    /// print-and-exit program that is evidence of absence, and the
    /// caller feeds the tracker's decay streak instead of idling.
    func classifyTask(
        _ task: Agent,
        input: AgentDetectionInput,
        cache: inout RegionCache
    ) -> AgentClassification? {
        firstMatchingRule(of: task, input: input, cache: &cache, identificationOnly: false)
    }

    /// Task adoption pass over the not-yet-held entries of the enabled
    /// families. Only working/blocked rules may identify — a summary
    /// line in scrollback must never mint a task — and the matching
    /// classification is returned with the entry so adoption and first
    /// classification are one evaluation. Prompt-family entries are
    /// excluded; `promptOverlay` owns them.
    func identifyTask(
        from input: AgentDetectionInput,
        families: Set<TaskFamily>,
        cache: inout RegionCache
    ) -> (task: Agent, classification: AgentClassification)? {
        for task in tasks {
            guard let family = task.family, family != .prompts,
                  families.contains(family) else { continue }
            if let classification = firstMatchingRule(
                of: task, input: input, cache: &cache, identificationOnly: true
            ) {
                return (task, classification)
            }
        }
        return nil
    }

    /// The universal-prompt pass: prompt-family entries, evaluated even
    /// while another task is held (a sudo prompt under `make` must still
    /// block the pane). All their rules are blocked rules.
    func promptOverlay(
        input: AgentDetectionInput,
        cache: inout RegionCache
    ) -> (task: Agent, classification: AgentClassification)? {
        for task in tasks {
            guard task.family == .prompts else { continue }
            if let classification = firstMatchingRule(
                of: task, input: input, cache: &cache, identificationOnly: false
            ) {
                return (task, classification)
            }
        }
        return nil
    }

    /// Extract + quantize a held task's progress. One capture group =
    /// percent; two = current/total. Bucketed to 10% steps so the row
    /// state changes at most ~10 times per run.
    func taskProgress(
        for task: Agent,
        input: AgentDetectionInput,
        cache: inout RegionCache
    ) -> String? {
        guard let pattern = task.progressPattern else { return nil }
        let region = cache.text(for: task.progressRegion)
        guard let match = (try? pattern.firstMatch(in: region.text)) ?? nil else { return nil }
        var numbers: [Int] = []
        for index in 1..<match.output.count {
            guard let range = match.output[index].range else { continue }
            if let value = Int(region.text[range]) { numbers.append(value) }
        }
        let percent: Int
        if numbers.count >= 2 {
            // Screen-captured ints are untrusted: bound them BEFORE the
            // multiply (a count over Int.max/100 would trap), and reject
            // implausible totals outright — no real build has a billion
            // steps, but hostile output can print one.
            let (current, total) = (numbers[0], numbers[1])
            guard total > 0, total <= 100_000_000, current <= total else { return nil }
            percent = current * 100 / total
        } else if numbers.count == 1 {
            percent = numbers[0]
        } else {
            return nil
        }
        guard (0...100).contains(percent) else { return nil }
        return "\((percent / 10) * 10)%"
    }

    private func firstMatchingRule(
        of task: Agent,
        input: AgentDetectionInput,
        cache: inout RegionCache,
        identificationOnly: Bool
    ) -> AgentClassification? {
        for rule in task.rules {
            if identificationOnly, rule.state != .working, rule.state != .blocked { continue }
            if rule.gate.matches(cache.text(for: rule.region)) {
                return AgentClassification(
                    state: rule.state,
                    visibleIdle: rule.visibleIdle,
                    visibleBlocker: rule.visibleBlocker,
                    visibleWorking: rule.visibleWorking,
                    skipStateUpdate: rule.skipStateUpdate,
                    matchedRuleID: rule.id,
                    matchedRuleRegion: rule.region
                )
            }
        }
        return nil
    }

    /// Evaluate only the OSC-fed rules (osc_title / osc_progress) — used
    /// on title changes without a screen read. Returns nil when no such
    /// rule matches (the caller keeps the previous state and schedules a
    /// screen scan instead).
    func classifyTitleOnly(agent: Agent, title: String, progress: String) -> AgentClassification? {
        let input = AgentDetectionInput(lines: [], oscTitle: title, oscProgress: progress)
        for rule in agent.rules where rule.region == "osc_title" || rule.region == "osc_progress" {
            let text = AgentDetectionRegions.extract(rule.region, from: input)
            if rule.gate.matches(RegionText(text)) {
                return AgentClassification(
                    state: rule.state,
                    visibleIdle: rule.visibleIdle,
                    visibleBlocker: rule.visibleBlocker,
                    visibleWorking: rule.visibleWorking,
                    skipStateUpdate: rule.skipStateUpdate,
                    matchedRuleID: rule.id,
                    matchedRuleRegion: rule.region
                )
            }
        }
        return nil
    }

    // MARK: - Loading

    private nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "AgentDetection")
    private static let maxGateDepth = 8

    /// The active manifest, loaded once. Two independent payloads merge
    /// before compile — the agent side (Documents override
    /// `AgentDetectionRules.json`, else embedded) and the task side
    /// (`TaskDetectionRules.json`, else embedded). Either side failing
    /// degrades to the other, never to nothing.
    @MainActor static let bundled: AgentDetectionManifest = load()

    private static func load() -> AgentDetectionManifest {
        let agentSide = loadSide(
            overrideName: "AgentDetectionRules.json",
            embedded: AgentDetectionManifestData.json,
            label: "agent")
        let taskSide = loadSide(
            overrideName: "TaskDetectionRules.json",
            embedded: AgentTaskManifestData.json,
            label: "task")
        return compile(agentSide: agentSide, taskSide: taskSide)
    }

    private static func loadSide(overrideName: String, embedded: String, label: String) -> ManifestFile? {
        let documents = ForkUITestConfiguration.documentsDirectoryURL
        let url = documents.appendingPathComponent(overrideName)
        if let data = try? Data(contentsOf: url),
           let file = decodeFile(data, source: "\(label) override") {
            return file
        }
        guard let data = embedded.data(using: .utf8) else {
            logger.error("embedded \(label, privacy: .public) manifest is not UTF-8; side disabled")
            return nil
        }
        return decodeFile(data, source: "embedded \(label)")
    }

    /// Test seam: compile explicit payloads with no Documents or bundle
    /// access, so the harness can exercise the compile-time bars.
    static func compile(agentJSON: String?, taskJSON: String?) -> AgentDetectionManifest {
        compile(
            agentSide: agentJSON.flatMap { decodeFile(Data($0.utf8), source: "test agent") },
            taskSide: taskJSON.flatMap { decodeFile(Data($0.utf8), source: "test task") }
        )
    }

    private static func decodeFile(_ data: Data, source: String) -> ManifestFile? {
        do {
            return try JSONDecoder().decode(ManifestFile.self, from: data)
        } catch {
            let message = String(describing: error)
            logger.error(
                "agent manifest (\(source, privacy: .public)) failed to decode: \(message, privacy: .public)")
            return nil
        }
    }

    /// Regions a task rule (or progress extractor) may address: live
    /// bottom-anchored text only. A scrollback-wide task rule would keep
    /// matching after Ctrl-C forever and defeat decay, so this is
    /// enforced at compile rather than trusted to authorship.
    private static func isTaskRegion(_ region: String) -> Bool {
        region == "osc_progress"
            || region.hasPrefix("bottom_lines(")
            || region.hasPrefix("bottom_non_empty_lines(")
    }

    private static func compile(agentSide: ManifestFile?, taskSide: ManifestFile?) -> AgentDetectionManifest {
        let file = ManifestFile(
            version: agentSide?.version,
            snapshotRows: agentSide?.snapshotRows ?? taskSide?.snapshotRows,
            agents: (agentSide?.agents ?? []) + (taskSide?.agents ?? [])
        )
        var agents: [Agent] = []
        var tasks: [Agent] = []
        for entry in file.agents {
            let kind: AttentionCategory
            switch entry.kind {
            case nil, "agent": kind = .agent
            case "task": kind = .task
            default:
                let id = entry.id, raw = entry.kind ?? ""
                logger.error(
                    """
                    entry \(id, privacy: .public): dropping unknown kind \
                    \(raw, privacy: .public)
                    """)
                continue
            }
            let family = entry.family.flatMap { TaskFamily(rawValue: $0) }
            if kind == .task, family == nil {
                let id = entry.id
                logger.error(
                    "task \(id, privacy: .public): dropping entry with missing/unknown family")
                continue
            }
            var titlePatterns: [Regex<AnyRegexOutput>] = []
            for pattern in entry.identity?.titlePatterns ?? [] {
                if let regex = try? Regex(pattern) {
                    titlePatterns.append(regex)
                } else {
                    let id = entry.id
                    logger.error("agent \(id, privacy: .public): dropping invalid titlePattern")
                }
            }

            var signatures: [Signature] = []
            for raw in entry.identity?.screenSignatures ?? [] {
                guard let gate = compileGate(raw.gate, agentID: entry.id, depth: 0),
                      gate.hasPositiveMatcher
                else {
                    let id = entry.id
                    logger.error("agent \(id, privacy: .public): dropping invalid screen signature")
                    continue
                }
                if let region = raw.region, !AgentDetectionRegions.isValidSpec(region) {
                    let id = entry.id
                    logger.error(
                        """
                        agent \(id, privacy: .public): dropping screen signature \
                        with unknown region \(region, privacy: .public)
                        """)
                    continue
                }
                signatures.append(Signature(
                    gate: gate,
                    weak: raw.altScreenOnly ?? false,
                    requiresAltScreen: raw.altScreenRequired ?? false,
                    region: raw.region
                ))
            }

            var rules: [Rule] = []
            for raw in entry.rules ?? [] {
                guard let state = AgentScreenState(rawValue: raw.state ?? "") else {
                    let id = entry.id, ruleID = raw.id ?? "?"
                    logger.error(
                        """
                        agent \(id, privacy: .public): dropping rule \
                        \(ruleID, privacy: .public) with unknown state
                        """)
                    continue
                }
                // Category contract, enforced here rather than trusted:
                // agent rules may never claim a terminal state (done is
                // idle-and-unseen, failed is an exit code), and task
                // rules may never claim idleness (no match = absent).
                if kind == .agent, state == .done || state == .failed {
                    let id = entry.id, ruleID = raw.id ?? "?"
                    logger.error(
                        """
                        agent \(id, privacy: .public): dropping rule \
                        \(ruleID, privacy: .public) with terminal state
                        """)
                    continue
                }
                if kind == .task, state == .idle || state == .unknown {
                    let id = entry.id, ruleID = raw.id ?? "?"
                    logger.error(
                        """
                        task \(id, privacy: .public): dropping rule \
                        \(ruleID, privacy: .public) with non-task state
                        """)
                    continue
                }
                let region = raw.region ?? "whole_recent"
                guard AgentDetectionRegions.isValidSpec(region) else {
                    let id = entry.id, ruleID = raw.id ?? "?"
                    logger.error(
                        """
                        agent \(id, privacy: .public): dropping rule \
                        \(ruleID, privacy: .public) with unknown region \
                        \(region, privacy: .public)
                        """)
                    continue
                }
                if kind == .task, !isTaskRegion(region) {
                    let id = entry.id, ruleID = raw.id ?? "?"
                    logger.error(
                        """
                        task \(id, privacy: .public): dropping rule \
                        \(ruleID, privacy: .public) with non-bottom region \
                        \(region, privacy: .public)
                        """)
                    continue
                }
                guard let gate = compileGate(raw.gate, agentID: entry.id, depth: 0),
                      gate.hasPositiveMatcher
                else {
                    let id = entry.id, ruleID = raw.id ?? "?"
                    logger.error(
                        """
                        agent \(id, privacy: .public): dropping rule \
                        \(ruleID, privacy: .public) with invalid/empty gate
                        """)
                    continue
                }
                rules.append(Rule(
                    id: raw.id ?? "rule\(rules.count)",
                    state: state,
                    priority: raw.priority ?? 0,
                    region: region,
                    visibleIdle: raw.visibleIdle ?? false,
                    visibleBlocker: raw.visibleBlocker ?? false,
                    visibleWorking: raw.visibleWorking ?? false,
                    skipStateUpdate: raw.skipStateUpdate ?? false,
                    gate: gate
                ))
            }
            // Priority descending; Swift's sort is not stable, so carry
            // the file index to keep deterministic first-on-tie semantics.
            rules = rules.enumerated()
                .sorted { ($0.element.priority, -$0.offset) > ($1.element.priority, -$1.offset) }
                .map(\.element)

            var progressPattern: Regex<AnyRegexOutput>?
            var progressRegion: String?
            if kind == .task, let rawProgress = entry.progress {
                let region = rawProgress.region ?? "bottom_non_empty_lines(4)"
                if let pattern = rawProgress.regex.flatMap({ try? Regex($0) }),
                   AgentDetectionRegions.isValidSpec(region), isTaskRegion(region) {
                    progressPattern = pattern
                    progressRegion = region
                } else {
                    let id = entry.id
                    logger.error("task \(id, privacy: .public): dropping invalid progress extractor")
                }
            }

            let compiled = Agent(
                id: entry.id,
                displayName: entry.displayName ?? entry.id,
                kind: kind,
                family: family,
                progressPattern: progressPattern,
                progressRegion: progressRegion,
                commands: Set(entry.identity?.commands ?? []),
                titlePatterns: titlePatterns,
                screenSignatures: signatures,
                rules: rules
            )
            if kind == .task {
                tasks.append(compiled)
            } else {
                agents.append(compiled)
            }
        }

        var byCommand: [String: Int] = [:]
        for (index, agent) in agents.enumerated() {
            for command in agent.commands {
                byCommand[command] = index
            }
        }
        let snapshotRows = max(10, min(file.snapshotRows ?? 40, 80))
        return AgentDetectionManifest(
            snapshotRows: snapshotRows, agents: agents, tasks: tasks, byCommand: byCommand)
    }

    private static func compileGate(_ raw: GateFile?, agentID: String, depth: Int) -> Gate? {
        guard let raw, depth < maxGateDepth else { return nil }
        var gate = Gate()
        gate.contains = (raw.contains ?? []).map { $0.lowercased() }
        for pattern in raw.regex ?? [] {
            guard let regex = try? Regex(pattern) else {
                logger.error("agent \(agentID, privacy: .public): invalid regex pattern")
                return nil
            }
            gate.regex.append(regex)
        }
        for pattern in raw.lineRegex ?? [] {
            guard let regex = try? Regex(pattern) else {
                logger.error("agent \(agentID, privacy: .public): invalid lineRegex pattern")
                return nil
            }
            gate.lineRegex.append(regex)
        }
        for nested in raw.all ?? [] {
            guard let compiled = compileGate(nested, agentID: agentID, depth: depth + 1) else { return nil }
            gate.all.append(compiled)
        }
        for nested in raw.any ?? [] {
            guard let compiled = compileGate(nested, agentID: agentID, depth: depth + 1) else { return nil }
            gate.any.append(compiled)
        }
        for nested in raw.not ?? [] {
            guard let compiled = compileGate(nested, agentID: agentID, depth: depth + 1) else { return nil }
            gate.not.append(compiled)
        }
        return gate
    }

    // MARK: - Raw Codable shapes (forward-tolerant: everything optional)

    private struct ManifestFile: Codable {
        var version: Int?
        var snapshotRows: Int?
        var agents: [AgentFile]
    }

    private struct AgentFile: Codable {
        var id: String
        var displayName: String?
        /// "agent" (default) or "task". Older app versions ignore this
        /// field entirely, which is why task entries ship in their own
        /// payload file those versions never read.
        var kind: String?
        var family: String?
        var progress: ProgressFile?
        var identity: IdentityFile?
        var rules: [RuleFile]?
    }

    private struct ProgressFile: Codable {
        var regex: String?
        var region: String?
    }

    private struct IdentityFile: Codable {
        var titlePatterns: [String]?
        var screenSignatures: [SignatureFile]?
        var commands: [String]?
    }

    private struct SignatureFile: Codable {
        var altScreenOnly: Bool?
        var altScreenRequired: Bool?
        var region: String?
        var contains: [String]?
        var regex: [String]?
        var lineRegex: [String]?
        var all: [GateFile]?
        var any: [GateFile]?
        var not: [GateFile]?

        var gate: GateFile {
            GateFile(contains: contains, regex: regex, lineRegex: lineRegex,
                     all: all, any: any, not: not)
        }
    }

    private struct GateFile: Codable {
        var contains: [String]?
        var regex: [String]?
        var lineRegex: [String]?
        var all: [GateFile]?
        var any: [GateFile]?
        var not: [GateFile]?
    }

    private struct RuleFile: Codable {
        var id: String?
        var state: String?
        var priority: Int?
        var region: String?
        var visibleIdle: Bool?
        var visibleBlocker: Bool?
        var visibleWorking: Bool?
        var skipStateUpdate: Bool?
        var contains: [String]?
        var regex: [String]?
        var lineRegex: [String]?
        var all: [GateFile]?
        var any: [GateFile]?
        var not: [GateFile]?

        /// The rule's own matcher fields, viewed as its root gate.
        var gate: GateFile {
            GateFile(contains: contains, regex: regex, lineRegex: lineRegex,
                     all: all, any: any, not: not)
        }
    }
}
