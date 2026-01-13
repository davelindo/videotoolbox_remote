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

    public mutating func recordSubmit() {
        latency.submit(at: DispatchTime.now().uptimeNanoseconds)
    }

    public mutating func recordOutput() {
        latency.output(at: DispatchTime.now().uptimeNanoseconds)
    }

    public mutating func discard() {
        latency.discardOne()
    }

    public func summary(mode: SessionMode) -> String {
        let elapsedNs = DispatchTime.now().uptimeNanoseconds &- startNanoseconds
        let elapsed = Double(elapsedNs) / 1_000_000_000.0
        let inMbps = elapsed > 0 ? Double(bytesIn * 8) / (elapsed * 1_000_000.0) : 0
        let outMbps = elapsed > 0 ? Double(bytesOut * 8) / (elapsed * 1_000_000.0) : 0

        switch mode {
        case .encode:
            return String(
                format: "SUMMARY mode=encode frames_in=%d packets_out=%d in=%lldB out=%lldB duration=%.3fs in_mbps=%.2f out_mbps=%.2f avg_encode_ms=%.2f max_encode_ms=%.2f",
                framesIn, packetsOut, bytesIn, bytesOut, elapsed, inMbps, outMbps, latency.averageMilliseconds, latency.maxMilliseconds
            )
        case .decode:
            return String(
                format: "SUMMARY mode=decode packets_in=%d frames_out=%d in=%lldB out=%lldB duration=%.3fs in_mbps=%.2f out_mbps=%.2f",
                packetsIn, framesOut, bytesIn, bytesOut, elapsed, inMbps, outMbps
            )
        }
    }
}
