import os

/// Security logs. Apple's Logger redacts interpolations by default. Do not pass phrases,
/// note text, keys, or attachment bytes into these messages.
enum VaultLog {
    static let security = Logger(subsystem: "com.notely.notes", category: "security")
}
