import os

/// os_signpost intervals and events for the multiplexer exposé pipeline:
/// detect, resolveSession, each tick, tick parsing, the pacing decision
/// between ticks, and per-tile paint. Shows up in Instruments under the
/// os_signpost track (subsystem com.rootshell, category MuxExpose -- the
/// same category `MultiplexerExposeFeed`'s `Logger` already uses) so a slow
/// exposé open can be attributed to a phase instead of guessed at. Near-zero
/// cost when not traced.
nonisolated enum MuxExposeSignposts {
    static let signposter = OSSignposter(subsystem: "com.rootshell", category: "MuxExpose")

    /// Stable id for one feed or one preview tile, so concurrent instances
    /// (more than one exposé feed, or several tiles painting at once) don't
    /// collide on a single shared `.exclusive` signpost lane.
    static func id(for object: AnyObject) -> OSSignpostID {
        signposter.makeSignpostID(from: object)
    }
}
