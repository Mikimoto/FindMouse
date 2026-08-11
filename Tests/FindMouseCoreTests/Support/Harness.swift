// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import FindMouseDomain
import FindMouseCore
import Foundation

/// 以固定 dt 推進狀態機，並記錄 phase 序列。
final class Harness {
    static let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    static let stage = Stage(union: screen, cursorScreen: screen)

    let session: CatSessionUseCase
    let config: StubConfig
    let catalog: StubCatalog

    private(set) var phases: [CatPhase] = []
    private(set) var last: CatFrameState

    init(config: StubConfig = StubConfig(), catalog: StubCatalog = StubCatalog(), seed: UInt64 = 42) {
        self.config = config
        self.catalog = catalog
        self.session = CatSessionUseCase(config: config, catalog: catalog,
                                         randomizer: SeededRandomizer(seed: seed))
        self.last = session.tick(dt: 0, cursor: CGPoint(x: 960, y: 540),
                                 stage: Self.stage, commands: [])
        self.phases = [last.phase]
    }

    /// 推進一步。dt 預設 1/60 秒。
    @discardableResult
    func step(dt: TimeInterval = 1.0 / 60, cursor: CGPoint = CGPoint(x: 960, y: 540),
              commands: [Command] = []) -> CatFrameState {
        last = session.tick(dt: dt, cursor: cursor, stage: Self.stage, commands: commands)
        if phases.last != last.phase { phases.append(last.phase) }
        return last
    }

    /// 推進到指定 phase 或超過上限。回傳是否抵達。
    @discardableResult
    func run(until target: CatPhase, cursor: CGPoint = CGPoint(x: 960, y: 540),
             maxSeconds: TimeInterval = 30) -> Bool {
        let maxSteps = Int(maxSeconds * 60)
        for _ in 0..<maxSteps {
            if last.phase == target { return true }
            step(cursor: cursor)
        }
        return last.phase == target
    }

    /// 推進固定秒數。
    func run(seconds: TimeInterval, cursor: CGPoint = CGPoint(x: 960, y: 540)) {
        for _ in 0..<Int(seconds * 60) { step(cursor: cursor) }
    }
}
