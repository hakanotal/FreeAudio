import Foundation
import Synchronization

/// Host time conversions (mach_absolute_time ticks).
enum HostClock {
    static let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1_000_000_000 * Double(info.denom) / Double(info.numer)
    }()

    static var now: UInt64 { mach_absolute_time() }
    static func ticks(_ seconds: Double) -> UInt64 { UInt64(max(seconds, 0) * ticksPerSecond) }
    static func seconds(_ ticks: UInt64) -> Double { Double(ticks) / ticksPerSecond }
}

/// One serial queue for all HAL setup and teardown (tap, aggregate, IOProc), so a teardown
/// always finishes before the next creation starts. HAL calls can block (another process's tap
/// on the same device, `AudioDeviceDestroyIOProcID` waiting for a cycle), so every operation has
/// a timeout. A timed-out call keeps running on the queue; the caller reports the engine as stuck
/// instead of retrying.
final class HALQueue: @unchecked Sendable {
    static let shared = HALQueue()

    enum Outcome: Sendable, Equatable {
        case done
        case failed(String)
        case timedOut
    }

    private let queue = DispatchQueue(label: "com.freeaudio.hal", qos: .userInitiated)

    /// Resumes a continuation at most once (work vs. timeout).
    private final class Once: Sendable {
        private let claimed = Atomic<Bool>(false)
        func claim() -> Bool { !claimed.exchange(true, ordering: .acquiringAndReleasing) }
    }

    func run(timeout: Double = 3, _ work: @escaping @Sendable () throws -> Void) async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let once = Once()
            queue.async {
                let outcome: Outcome
                do {
                    try work()
                    outcome = .done
                } catch {
                    outcome = .failed(error.localizedDescription)
                }
                if once.claim() { continuation.resume(returning: outcome) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: .timedOut) }
            }
        }
    }

    /// Blocking variant for app termination. Returns false if `work` didn't finish in time.
    @discardableResult
    func runAndWait(timeout: Double, _ work: @escaping @Sendable () -> Void) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        queue.async {
            work()
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + timeout) == .success
    }
}
