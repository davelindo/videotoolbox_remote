import Foundation

/// Tracks DTS/PTS values to ensure correct timestamp behavior for video encoding.
///
/// VideoToolbox callbacks can fire concurrently and may produce duplicate frames.
/// This tracker ensures:
/// 1. Duplicate PTS values are detected and can be skipped
/// 2. DTS is always <= PTS (decode before present)
/// 3. DTS is strictly monotonically increasing (required by muxers)
final class TimestampTracker: @unchecked Sendable {
    private var lastDtsTicks: Int64 = Int64.min
    private var lastPtsTicks: Int64 = Int64.min
    private let lock = NSLock()
    
    /// Resets the tracker state for a new session.
    func reset() {
        lock.withLock {
            lastDtsTicks = Int64.min
            lastPtsTicks = Int64.min
        }
    }
    
    /// Result of processing a timestamp pair.
    enum Result {
        /// The frame should be skipped (duplicate PTS)
        case skip
        /// The frame should be emitted with this DTS
        case emit(dts: Int64)
    }
    
    /// Processes a PTS/DTS pair and returns whether to emit or skip.
    ///
    /// - Parameters:
    ///   - ptsTicks: Presentation timestamp in timebase ticks
    ///   - dtsTicks: Decode timestamp in timebase ticks (may be adjusted)
    /// - Returns: `.skip` if duplicate PTS, otherwise `.emit(dts:)` with corrected DTS
    func process(ptsTicks: Int64, dtsTicks: Int64) -> Result {
        lock.withLock {
            // Skip duplicate PTS values (VideoToolbox can produce duplicate callbacks)
            if ptsTicks == lastPtsTicks && lastPtsTicks != Int64.min {
                return .skip
            }
            
            var dts = dtsTicks
            
            // Ensure DTS <= PTS
            if dts > ptsTicks {
                dts = ptsTicks
            }
            
            // Ensure strict monotonicity: DTS must be > lastDtsTicks
            if lastDtsTicks != Int64.min && dts <= lastDtsTicks {
                dts = lastDtsTicks + 1
            }
            
            // Final safety: if monotonicity pushed DTS above PTS, clamp to PTS
            if dts > ptsTicks {
                dts = ptsTicks
            }
            
            lastPtsTicks = ptsTicks
            lastDtsTicks = dts
            
            return .emit(dts: dts)
        }
    }
}
