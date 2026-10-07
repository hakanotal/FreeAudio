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
/// on the same device, a device that is still waking up, `AudioDeviceDestroyIOProcID` waiting
/// for a cycle). Callers always get the real outcome, however long it takes, so they never act
/// on a guess (e.g. retire an old engine while its replacement is still starting); `busySeconds`
/// lets them show a "stuck" notice meanwhile.
final class HALQueue: @unchecked Sendable {
    static let shared = HALQueue()

    enum Outcome: Sendable, Equatable {
        case done
        case failed(String)
    }

    private let queue = DispatchQueue(label: "com.freeaudio.hal", qos: .userInitiated)
    /// Host time at which the running work item started; 0 while the queue is idle.
    private let runningSince = Atomic<UInt64>(0)

    /// How long the work item running now has taken so far (0 when idle). Counted from when it
    /// started, not when it was queued, so work waiting behind one slow call doesn't look stuck.
    var busySeconds: Double {
        let since = runningSince.load(ordering: .relaxed)
        return since == 0 ? 0 : HostClock.seconds(HostClock.now &- since)
    }

    func run(_ work: @escaping @Sendable () throws -> Void) async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            queue.async {
                self.runningSince.store(HostClock.now, ordering: .relaxed)
                let outcome: Outcome
                do {
                    try work()
                    outcome = .done
                } catch {
                    outcome = .failed(error.localizedDescription)
                }
                self.runningSince.store(0, ordering: .relaxed)
                continuation.resume(returning: outcome)
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
