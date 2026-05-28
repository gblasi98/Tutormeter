import Foundation

// MARK: - Date Provider

/// Abstraction over the current wall-clock time, enabling deterministic
/// tests by injecting a custom date source instead of calling `Date()`
/// directly inside production code.
///
/// All Tutormeter subsystems that need to read "now" should accept a
/// `DateProvider` (defaulting to `SystemDateProvider()`) rather than
/// hard-coding `Date()`. Tests can then provide a frozen or controllable
/// clock to exercise time-dependent logic without flakiness.
public protocol DateProvider: Sendable {
    /// Returns the current wall-clock time.
    func now() -> Date
}

/// Production date provider that returns the actual current time.
public struct SystemDateProvider: DateProvider {
    public init() {}
    public func now() -> Date { Date() }
}
