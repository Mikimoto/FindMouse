import Foundation
import Testing
@testable import FindMouseDomain

@Test func seededRandomizerIsDeterministic() {
    let a = SeededRandomizer(seed: 42)
    let b = SeededRandomizer(seed: 42)
    for _ in 0..<20 {
        #expect(a.double(in: 0...1) == b.double(in: 0...1))
    }
}

@Test func seededRandomizerDiffersBySeed() {
    let a = SeededRandomizer(seed: 1)
    let b = SeededRandomizer(seed: 2)
    #expect(a.double(in: 0...1) != b.double(in: 0...1))
}

@Test func doubleStaysInRange() {
    let r = SeededRandomizer(seed: 7)
    for _ in 0..<200 {
        let v = r.double(in: 2...4)
        #expect(v >= 2 && v <= 4)
    }
}

@Test func pickReturnsNilForEmptyAndMemberOtherwise() {
    let r = SeededRandomizer(seed: 3)
    #expect(r.pick([Int]()) == nil)
    let items = [10, 20, 30]
    for _ in 0..<50 {
        let picked = r.pick(items)
        #expect(picked != nil)
        #expect(items.contains(picked!))
    }
}
