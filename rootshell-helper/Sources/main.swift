//
//  main.swift
//  rootshell-helper
//
//  Main entry point for the rootshell-helper service
//

import Foundation

// MARK: - Main

NSLog("rootshell-helper starting...")

// The spawning app passes --app-group so app and helper agree on the socket
// container. A separately launched helper falls back to the compiled-in value.
let arguments = CommandLine.arguments
if let flagIndex = arguments.firstIndex(of: "--app-group"), flagIndex + 1 < arguments.count {
    AppGroupHelper.overrideGroupIdentifier = arguments[flagIndex + 1]
    NSLog("Using app group from argv: \(arguments[flagIndex + 1])")
}
if let flagIndex = arguments.firstIndex(of: "--socket-directory"), flagIndex + 1 < arguments.count {
    AppGroupHelper.overrideContainerURL = URL(fileURLWithPath: arguments[flagIndex + 1], isDirectory: true)
    NSLog("Using socket directory from argv")
}

// Create socket command server
let server = SocketCommandServer()

// Handle termination signals gracefully
signal(SIGTERM) { _ in
    NSLog("Received SIGTERM, cleaning up...")
    SessionManager.shared.cleanup()
    exit(0)
}

signal(SIGINT) { _ in
    NSLog("Received SIGINT, cleaning up...")
    SessionManager.shared.cleanup()
    exit(0)
}

// Start socket server
do {
    try server.start()
    NSLog("rootshell-helper socket server started successfully")
} catch {
    NSLog("Failed to start socket server: \(error)")
    exit(1)
}

// Run forever
RunLoop.main.run()
