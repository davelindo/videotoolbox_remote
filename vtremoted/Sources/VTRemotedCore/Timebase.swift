import Foundation

public struct RationalTime: Equatable, Sendable {
    public var value: Int64
    public var timescale: Int32

    public init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = max(1, timescale)
    }

    public var seconds: Double {
        Double(value) / Double(timescale)
    }
}

public struct Timebase: Equatable, Sendable {
    public var num: Int
    public var den: Int

    public init(num: Int, den: Int) {
        self.num = max(1, num)
        self.den = max(1, den)
    }

    public func time(fromTicks ticks: Int64) -> RationalTime {
        let (value, overflow) = ticks.multipliedReportingOverflow(by: Int64(num))
        let safe = overflow ? (ticks >= 0 ? Int64.max : Int64.min) : value
        return RationalTime(value: safe, timescale: Int32(den))
    }

    public func ticks(from time: RationalTime) -> Int64 {
        let targetScale = Int64(max(1, den))
        let srcScale = Int64(max(1, time.timescale))
        let (mul, overflow) = time.value.multipliedReportingOverflow(by: targetScale)
        let safeMul = overflow ? (time.value >= 0 ? Int64.max : Int64.min) : mul
        let scaled = safeMul / srcScale
        return scaled / Int64(max(1, num))
    }
}
