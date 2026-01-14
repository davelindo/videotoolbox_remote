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

    public mutating func maybeReport(mode: SessionMode, logger: Logger, intervalSeconds: Double = 1.0) {
        guard logger.level.rawValue >= LogLevel.debug.rawValue else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsedNs = now &- lastReportNanoseconds
        let minNs = UInt64(intervalSeconds * 1_000_000_000.0)
        guard elapsedNs >= minNs else { return }

        let elapsed = Double(elapsedNs) / 1_000_000_000.0
        let deltaIn = bytesIn - lastReportBytesIn
        let deltaOut = bytesOut - lastReportBytesOut
        let inMbps = elapsed > 0 ? Double(deltaIn * 8) / (elapsed * 1_000_000.0) : 0
        let outMbps = elapsed > 0 ? Double(deltaOut * 8) / (elapsed * 1_000_000.0) : 0

        logger.debug(
            String(
                format: "WIRE mode=%@ inst_in_mbps=%.2f inst_out_mbps=%.2f " +
                    "totals_in=%lldB totals_out=%lldB",
                mode.rawValue, inMbps, outMbps, bytesIn, bytesOut
            )
        )

        lastReportNanoseconds = now
        lastReportBytesIn = bytesIn
        lastReportBytesOut = bytesOut
    }

    public func summary(mode: SessionMode) -> String {
        let elapsedNs = DispatchTime.now().uptimeNanoseconds &- startNanoseconds
        let elapsed = Double(elapsedNs) / 1_000_000_000.0
        let inMbps = elapsed > 0 ? Double(bytesIn * 8) / (elapsed * 1_000_000.0) : 0
        let outMbps = elapsed > 0 ? Double(bytesOut * 8) / (elapsed * 1_000_000.0) : 0

        switch mode {
        case .encode:
            return String(
                format: "SUMMARY mode=encode frames_in=%d packets_out=%d in=%lldB out=%lldB " +
                    "duration=%.3fs in_mbps=%.2f out_mbps=%.2f avg_encode_ms=%.2f max_encode_ms=%.2f",
                framesIn, packetsOut, bytesIn, bytesOut, elapsed, inMbps, outMbps,
                latency.averageMilliseconds, latency.maxMilliseconds
            )
        case .decode:
            return String(
                format: "SUMMARY mode=decode packets_in=%d frames_out=%d in=%lldB out=%lldB " +
                    "duration=%.3fs in_mbps=%.2f out_mbps=%.2f",
                packetsIn, framesOut, bytesIn, bytesOut, elapsed, inMbps, outMbps
            )
        }
    }
}
