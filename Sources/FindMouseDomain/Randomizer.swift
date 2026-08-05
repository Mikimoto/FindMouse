import Foundation

/// 可注入的隨機來源。用 AnyObject 約束，讓實作可以持有可變狀態
/// 而不需要在 existential 上處理 mutating。
public protocol Randomizer: AnyObject, Sendable {
    func double(in range: ClosedRange<Double>) -> Double
    func pick<T>(_ items: [T]) -> T?
}

/// 正式執行時使用。
public final class SystemRandomizer: Randomizer, @unchecked Sendable {
    public init() {}

    public func double(in range: ClosedRange<Double>) -> Double {
        Double.random(in: range)
    }

    public func pick<T>(_ items: [T]) -> T? {
        items.randomElement()
    }
}

/// 測試與可重現除錯用。SplitMix64。
public final class SeededRandomizer: Randomizer, @unchecked Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    private func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// [0, 1) 的均勻分佈
    private func unitDouble() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    public func double(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + unitDouble() * (range.upperBound - range.lowerBound)
    }

    public func pick<T>(_ items: [T]) -> T? {
        guard !items.isEmpty else { return nil }
        return items[Int(next() % UInt64(items.count))]
    }
}
