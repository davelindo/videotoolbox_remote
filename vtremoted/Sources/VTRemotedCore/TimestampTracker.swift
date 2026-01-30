import Foundation

/// Tracks DTS/PTS values to ensure correct timestamp behavior for video encoding.
///
/// VideoToolbox callbacks can fire concurrently and may produce duplicate frames.
/// This tracker ensures:
/// 1. DTS is strictly monotonically increasing (required by muxers)
/// 2. PTS can be enforced monotonic when reordering is disabled
final class TimestampTracker: @unchecked Sendable {
    private var lastDtsTicks: Int64 = Int64.min
    private var lastPtsTicks: Int64 = Int64.min
    private var enforceMonotonicPts: Bool = true
    private let lock = NSLock()
    
    /// Resets the tracker state for a new session.
    func reset(enforceMonotonicPts: Bool? = nil) {
        lock.withLock {
            lastDtsTicks = Int64.min
            lastPtsTicks = Int64.min
            if let enforceMonotonicPts {
                self.enforceMonotonicPts = enforceMonotonicPts
            }
        }
    }
    
    /// Result of processing a timestamp pair.
    enum Result {
        /// The frame should be emitted with adjusted PTS/DTS
        case emit(pts: Int64, dts: Int64, ptsAdjusted: Bool)
    }
    
    /// Processes a PTS/DTS pair and returns adjusted timestamps.
    ///
    /// - Parameters:
    ///   - ptsTicks: Presentation timestamp in timebase ticks
    ///   - dtsTicks: Decode timestamp in timebase ticks (may be adjusted)
    /// - Returns: `.emit(pts:dts:ptsAdjusted:)` with corrected timestamps
    func process(ptsTicks: Int64, dtsTicks: Int64) -> Result {
        lock.withLock {
            var pts = ptsTicks
            var dts = dtsTicks
            var ptsAdjusted = false

            // Ensure strict monotonicity: DTS must be > lastDtsTicks
            if lastDtsTicks != Int64.min && dts <= lastDtsTicks {
                dts = lastDtsTicks + 1
            }

            if enforceMonotonicPts {
                if lastPtsTicks != Int64.min && pts <= lastPtsTicks {
                    pts = lastPtsTicks + 1
                    ptsAdjusted = true
                }
                if dts > pts {
                    pts = dts
                    ptsAdjusted = true
                }
            }

            lastPtsTicks = pts
            lastDtsTicks = dts
            
            return .emit(pts: pts, dts: dts, ptsAdjusted: ptsAdjusted)
        }
    }
}
