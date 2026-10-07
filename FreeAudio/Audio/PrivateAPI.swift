import Darwin
import Foundation

/// Private system functions FreeAudio uses (approved by the user on 2026-10-06). Each is looked
/// up with `dlsym` at runtime, so a missing symbol degrades the feature instead of crashing.
enum PrivateAPI {
    private typealias ResponsibilityFn = @convention(c) (pid_t) -> pid_t
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    /// RTLD_DEFAULT is a cast macro Swift doesn't import.
    private nonisolated(unsafe) static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    private static let responsibility: ResponsibilityFn? = dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: ResponsibilityFn.self) }

    // Resolved once: the status is checked on every reconcile until it is answered.
    private nonisolated(unsafe) static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let preflight: PreflightFn? = tcc.flatMap { dlsym($0, "TCCAccessPreflight") }
        .map { unsafeBitCast($0, to: PreflightFn.self) }
    private static let request: RequestFn? = tcc.flatMap { dlsym($0, "TCCAccessRequest") }
        .map { unsafeBitCast($0, to: RequestFn.self) }
    private nonisolated(unsafe) static let audioCaptureService = "kTCCServiceAudioCapture" as CFString

    /// The process macOS holds responsible for `pid` (e.g. Safari or Outlook for a WebKit XPC
    /// process). nil when unknown or when the function is unavailable.
    static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let responsibility else { return nil }
        let result = responsibility(pid)
        return result > 0 ? result : nil
    }

    enum AudioCaptureStatus: Sendable {
        case authorized, denied, notDetermined, unavailable
    }

    /// System Audio Recording permission without prompting.
    static func audioCaptureStatus() -> AudioCaptureStatus {
        guard let preflight else { return .unavailable }
        switch preflight(audioCaptureService, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .notDetermined
        }
    }

    /// Shows the System Audio Recording prompt if the user hasn't answered it yet.
    /// `completion` runs on an arbitrary queue. Returns false when the function is unavailable.
    @discardableResult
    static func requestAudioCapture(_ completion: @escaping @Sendable (Bool) -> Void) -> Bool {
        guard let request else { return false }
        request(audioCaptureService, nil) { granted in completion(granted) }
        return true
    }
}

/// Full path of a process's executable, or nil.
func executablePath(forPID pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
}
