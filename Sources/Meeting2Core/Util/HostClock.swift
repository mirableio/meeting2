import Darwin
import Foundation

// Converts differences between mach host timestamps into milliseconds. Host time is
// the clock used to align the two recordings because it is monotonic (never jumps) and
// both AVAudioEngine and Core Audio stamp their buffers with it — so the mic's and the
// system track's timestamps are directly comparable.
public enum HostClock {
    public static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        // Host-time units are not nanoseconds; the ratio that converts them is
        // hardware-specific, so ask the kernel for it (numer/denom) rather than
        // assuming. The subtraction is done in unsigned space then re-signed, so a
        // later-than / earlier-than pair yields a correctly signed millisecond delta.
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)

        let ticks = end >= start ? end - start : start - end
        let nanos = Double(ticks) * Double(info.numer) / Double(info.denom)
        let millis = nanos / 1_000_000.0
        return end >= start ? millis : -millis
    }
}
