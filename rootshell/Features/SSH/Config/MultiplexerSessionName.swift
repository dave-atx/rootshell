//
//  MultiplexerSessionName.swift
//  rootshell
//
//  Which configured session names are safe to embed in a multiplexer command.
//

nonisolated enum MultiplexerSessionName {
    /// herdr session names are ASCII alphanumerics plus `.`, `_`, and `-`, at
    /// most 64 bytes, excluding the reserved `.` and `..` names.
    static func isEmbeddableHerdr(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 64 && name.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-")
        }
    }

    /// The shared configured-name rule. It must not be applied to names from
    /// `zmx list`, which may legally contain characters this rule rejects.
    static func isEmbeddable(_ name: String) -> Bool {
        isEmbeddableHerdr(name)
    }

    /// zmx also rejects a leading dash: `zmx attach` would parse it as an
    /// option instead of a session name.
    static func isEmbeddableZmx(_ name: String) -> Bool {
        isEmbeddable(name) && !name.hasPrefix("-")
    }
}
