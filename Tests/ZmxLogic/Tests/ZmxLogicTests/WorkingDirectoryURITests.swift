import Testing
@testable import ZmxLogic

@Suite("WorkingDirectoryURI")
struct WorkingDirectoryURITests {
    @Test("Decodes an OSC 7 URI into its path")
    func decodesURI() {
        #expect(WorkingDirectoryURI.path("file://build-host/var/work/api") == "/var/work/api")
    }

    @Test("Percent-decodes an OSC 7 path")
    func decodesPercentEncoding() {
        #expect(WorkingDirectoryURI.path("file://build-host/var/work/web%20app") == "/var/work/web app")
    }

    @Test("Passes a bare path through unchanged", arguments: ["/var/work/api", "/var/work/web app", "/tmp/100%done", "/tmp/50%20"])
    func barePathUntouched(path: String) {
        #expect(WorkingDirectoryURI.path(path) == path)
    }

    @Test("Falls back to a malformed URI", arguments: ["file://", "file://build-host"])
    func malformedURIFallsBack(value: String) {
        #expect(WorkingDirectoryURI.path(value) == value)
    }
}
