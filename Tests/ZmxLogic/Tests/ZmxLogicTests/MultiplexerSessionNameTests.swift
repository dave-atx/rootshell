import Testing
@testable import ZmxLogic

@Suite("MultiplexerSessionName")
struct MultiplexerSessionNameTests {
    @Test("Accepts the documented charset", arguments: ["main", "my-session", "a_b.c", "session1", "A.b_c-4"])
    func acceptsLegalNames(name: String) {
        #expect(MultiplexerSessionName.isEmbeddable(name))
        #expect(MultiplexerSessionName.isEmbeddableZmx(name))
    }

    @Test("Rejects the empty name and reserved dot names", arguments: ["", ".", ".."])
    func rejectsReserved(name: String) {
        #expect(!MultiplexerSessionName.isEmbeddable(name))
        #expect(!MultiplexerSessionName.isEmbeddableZmx(name))
    }

    @Test("Rejects characters outside the charset", arguments: ["has space", "star*", "quote\"", "slash/name", "tab\tname", "café"])
    func rejectsIllegalCharacters(name: String) {
        #expect(!MultiplexerSessionName.isEmbeddable(name))
        #expect(!MultiplexerSessionName.isEmbeddableZmx(name))
    }

    @Test("Caps names at 64 bytes")
    func capsLength() {
        #expect(MultiplexerSessionName.isEmbeddable(String(repeating: "a", count: 64)))
        #expect(!MultiplexerSessionName.isEmbeddable(String(repeating: "a", count: 65)))
    }

    @Test("Rejects a leading dash for zmx only", arguments: ["-d", "--labels", "-main", "-"])
    func rejectsLeadingDashForZmx(name: String) {
        #expect(!MultiplexerSessionName.isEmbeddableZmx(name))
    }

    @Test("The zmx rule differs only by its leading-dash check", arguments: ["main", "-d", "a-b", "", ".", "has space", "-", "--x", "ab-"])
    func differsOnlyOnLeadingDash(name: String) {
        #expect(MultiplexerSessionName.isEmbeddableZmx(name)
                == (MultiplexerSessionName.isEmbeddable(name) && !name.hasPrefix("-")))
    }

    @Test("herdr matches the shared rule", arguments: ["main", "", ".", "..", "a-b", "has space", "-d"])
    func herdrMatchesShared(name: String) {
        #expect(MultiplexerSessionName.isEmbeddableHerdr(name) == MultiplexerSessionName.isEmbeddable(name))
    }
}
