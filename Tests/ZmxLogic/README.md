# ZmxLogic tests

Fork-only standalone tests for dependency-free zmx-related app logic.

```sh
swift test --package-path Tests/ZmxLogic
```

The two files under `Sources/ZmxLogic/` are symlinks to production sources:

- `WorkingDirectoryURI.swift` → `rootshell/Core/Terminal/WorkingDirectoryURI.swift`
- `MultiplexerSessionName.swift` → `rootshell/Features/SSH/Config/MultiplexerSessionName.swift`

This keeps the package out of the Xcode project while exercising the exact
rules used by the app. It covers OSC 7 working-directory decoding and the
configured-name rules for herdr and zmx. Names discovered by `zmx list` are
intentionally outside the configured-name validation rules.
