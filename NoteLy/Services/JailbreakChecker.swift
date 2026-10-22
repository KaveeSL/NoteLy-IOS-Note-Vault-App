import Foundation

/// Best-effort signals that the device is modified. This is not a security boundary:
/// a modified device can hide every check here. The only response is a warning inside vault settings.
enum JailbreakChecker {
    static var hasSuspiciousEnvironment: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        if suspiciousFileExists { return true }
        if getenv("DYLD_INSERT_LIBRARIES") != nil { return true }
        if canWriteOutsideSandbox { return true }
        return false
        #endif
    }

    private static var suspiciousFileExists: Bool {
        let paths = [
            "/Applications/Cydia.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/bin/bash",
            "/usr/sbin/sshd",
            "/etc/apt",
            "/private/var/lib/apt/"
        ]
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    private static var canWriteOutsideSandbox: Bool {
        let path = "/private/notely_sandbox_probe.txt"
        do {
            try "probe".write(toFile: path, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            return false
        }
    }
}
