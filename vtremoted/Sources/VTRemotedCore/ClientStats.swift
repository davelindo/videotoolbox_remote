import Foundation

public struct ClientStats: Sendable {
    public var framesIn = 0
    public var framesOut = 0
    public var packetsIn = 0
    public var packetsOut = 0
    public var bytesIn: Int64 = 0
    public var bytesOut: Int64 = 0
    public var latency = LatencyTracker()
    public var startNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    public var lastReportNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    public var lastReportBytesIn: Int64 = 0
    public var lastReportBytesOut: Int64 = 0

    public mutating func recordSubmit() {
        latency.submit(at: DispatchTime.now().uptimeNanoseconds)
    }

    public mutating func recordOutput() {
        latency.output(at: DispatchTime.now().uptimeNanoseconds)
    }

    public mutating func discard() {
        latency.discardOne()
    }

    private static func mbps(bytes: Int64, elapsedSeconds: Double) -> Double {
        guard elapsedSeconds > 0 else { return 0 }
        return Double(bytes * 8) / (elapsedSeconds * 1_000_000.0)
    }

    public mutating func reportIfDue(mode: SessionMode, intervalSeconds: Double = 1.0) -> String? {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsedNs = now &- lastReportNanoseconds
        let minNs = UInt64(intervalSeconds * 1_000_000_000.0)
        guard elapsedNs >= minNs else { return nil }

        let elapsed = Double(elapsedNs) / 1_000_000_000.0
        let deltaIn = bytesIn - lastReportBytesIn
        let deltaOut = bytesOut - lastReportBytesOut
        let inMbps = Self.mbps(bytes: deltaIn, elapsedSeconds: elapsed)
        let outMbps = Self.mbps(bytes: deltaOut, elapsedSeconds: elapsed)

        let report = String(
            format: "WIRE mode=%@ inst_in_mbps=%.2f inst_out_mbps=%.2f " +
                "totals_in=%lldB totals_out=%lldB",
            mode.rawValue, inMbps, outMbps, bytesIn, bytesOut
        )

        lastReportNanoseconds = now
        lastReportBytesIn = bytesIn
        lastReportBytesOut = bytesOut
        return report
    }

    public func summary(mode: SessionMode) -> String {
        let elapsedNs = DispatchTime.now().uptimeNanoseconds &- startNanoseconds
        let elapsed = Double(elapsedNs) / 1_000_000_000.0
        let inMbps = Self.mbps(bytes: bytesIn, elapsedSeconds: elapsed)
        let outMbps = Self.mbps(bytes: bytesOut, elapsedSeconds: elapsed)
        let percentiles = String(
            format: " latency_samples=%llu server_p50_ms=%.3f server_p95_ms=%.3f server_p99_ms=%.3f",
            latency.sampleCount, latency.percentileMilliseconds(0.50),
            latency.percentileMilliseconds(0.95), latency.percentileMilliseconds(0.99)
        ) + " latency_histogram=\(latency.histogramSummary)"

        switch mode {
        case .encode:
            return String(
                format: "SUMMARY mode=encode frames_in=%d packets_out=%d in=%lldB out=%lldB " +
                    "duration=%.3fs in_mbps=%.2f out_mbps=%.2f avg_encode_ms=%.2f max_encode_ms=%.2f",
                framesIn, packetsOut, bytesIn, bytesOut, elapsed, inMbps, outMbps,
                latency.averageMilliseconds, latency.maxMilliseconds
            ) + percentiles
        case .decode:
            return String(
                format: "SUMMARY mode=decode packets_in=%d frames_out=%d in=%lldB out=%lldB " +
                    "duration=%.3fs in_mbps=%.2f out_mbps=%.2f",
                packetsIn, framesOut, bytesIn, bytesOut, elapsed, inMbps, outMbps
            ) + percentiles
        case .transcode:
            return String(
                format: "SUMMARY mode=transcode packets_in=%d packets_out=%d in=%lldB out=%lldB " +
                    "duration=%.3fs in_mbps=%.2f out_mbps=%.2f",
                packetsIn, packetsOut, bytesIn, bytesOut, elapsed, inMbps, outMbps
            ) + percentiles
        }
    }
}

/// Protects counters and the latency queue together; logging uses detached snapshots.
public final class LockedClientStats: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ClientStats()

    public func update(_ body: (inout ClientStats) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&value)
    }

    public func snapshot() -> ClientStats {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func maybeReport(mode: SessionMode, logger: Logger, intervalSeconds: Double = 1) {
        guard logger.level.rawValue >= LogLevel.debug.rawValue else { return }
        lock.lock()
        let report = value.reportIfDue(mode: mode, intervalSeconds: intervalSeconds)
        lock.unlock()
        if let report { logger.debug(report) }
    }
}
