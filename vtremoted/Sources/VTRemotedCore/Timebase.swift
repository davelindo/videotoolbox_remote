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
        return RationalTime(value: safe, timescale: Int32(clamping: den))
    }

    public func ticks(from time: RationalTime) -> Int64 {
        let targetScale = UInt64(max(1, den))
        let srcScale = UInt64(max(1, time.timescale))
        let numerator = UInt64(max(1, num))
        let product = time.value.magnitude.multipliedFullWidth(by: targetScale)
        let magnitude: UInt64
        if product.high == 0 {
            magnitude = product.low / srcScale / numerator
        } else {
            // Keep both words after the first division: its quotient may exceed
            // UInt64 even when division by the timebase numerator brings it in range.
            // Positive divisors make staged truncation equivalent to one division.
            let high = product.high / srcScale
            let low = srcScale.dividingFullWidth((high: product.high % srcScale, low: product.low)).quotient
            guard high < numerator else {
                return time.value < 0 ? Int64.min : Int64.max
            }
            magnitude = numerator.dividingFullWidth((high: high, low: low)).quotient
        }
        if time.value >= 0 {
            return Int64(clamping: magnitude)
        }
        guard magnitude <= UInt64(Int64.max) else { return Int64.min }
        return -Int64(magnitude)
    }
}
