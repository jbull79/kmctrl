import Foundation

/// True inside a Debug build launched by XCTest. Hosted tests start the real app, and that build
/// must leave this Mac's real KMctrl alone: reading its Keychain item raises a login-password
/// prompt on every launch, and its listener and Bonjour name would compete with the installed
/// app's. Always false in Release, so the environment can't change how a shipped app behaves.
enum TestRun {
    #if DEBUG
    static let isActive = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    #else
    static let isActive = false
    #endif
}
