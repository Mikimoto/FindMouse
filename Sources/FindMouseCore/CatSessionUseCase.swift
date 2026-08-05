import CoreGraphics
import FindMouseDomain
import Foundation

/// M1 唯一持有可變狀態的型別。spec 第 4 節的狀態機。
///
/// 狀態集中在這一處是刻意的：整個 App 的行為因此可以用一串 tick 完整斷言，
/// 不需要開視窗。
public final class CatSessionUseCase {

    private let config: ConfigProviderPort
    private let catalog: AnimationCatalogPort
    private let randomizer: Randomizer

    // 狀態
    private var phase: CatPhase = .hidden
    private var body = CatBody(position: .zero, heading: 0)
    private var phaseElapsed: TimeInterval = 0
    private var actionElapsed: TimeInterval = 0
    private var currentAction: CatAction = .sitIdle
    private var restTimer: TimeInterval = 0
    private var sleepTimer: TimeInterval = 0
    private var flourishTimer: TimeInterval = 0
    private var flourishInterval: TimeInterval = 0
    private var activeFlourish: CatAction?
    private var teaserEnabled = false
    private var pendingExit = false
    private var spotlightOpacity: CGFloat = 0
    private var spotlightArmed = false
    private var alpha: CGFloat = 1
    private var exitTarget: CGPoint = .zero
    private var pounceTarget: CGPoint = .zero
    private var retreatPoint: CGPoint = .zero
    private var previousCursor: CGPoint?
    private var cursorSpeed: CGFloat = 0
    private var stage = Stage(union: .zero, cursorScreen: .zero)

    public init(config: ConfigProviderPort, catalog: AnimationCatalogPort, randomizer: Randomizer) {
        self.config = config
        self.catalog = catalog
        self.randomizer = randomizer
    }

    // MARK: - tick

    /// 推進一帧。dt 會被 clamp 在 Timings.maxTickDelta，防止系統睡眠喚醒後貓瞬移。
    public func tick(dt rawDt: TimeInterval, cursor: CGPoint,
                     stage: Stage, commands: [Command]) -> CatFrameState {
        // NaN 通不過 clamp（min/max 對 NaN 是恆等），而 Int(actionElapsed * fps)
        // 會直接 trap。M2 的 driver 由時間戳相減算 dt，所以擋在這裡最省。
        let dt = rawDt.isFinite ? min(max(rawDt, 0), Timings.maxTickDelta) : 0
        let cfg = config.config
        self.stage = stage

        updateCursorSpeed(cursor: cursor, dt: dt)
        for command in commands {
            apply(command, cursor: cursor, cfg: cfg)
        }
        advance(dt: dt, cursor: cursor, cfg: cfg)
        return makeState(cursor: cursor, cfg: cfg)
    }

    // MARK: - 命令

    private func apply(_ command: Command, cursor: CGPoint, cfg: BehaviorConfig) {
        switch command {
        case .summon:
            summon(cursor: cursor, cfg: cfg)
        case .dismiss:
            goHome()
        case .toggle:
            if phase.isVisible && phase != .exiting { goHome() } else { summon(cursor: cursor, cfg: cfg) }
        case .setTeaser(let on):
            setTeaser(on, cursor: cursor, cfg: cfg)
        case .toggleTeaser:
            setTeaser(!teaserEnabled, cursor: cursor, cfg: cfg)
        }
    }

    /// 幂等：對已在場的貓是 no-op。
    private func summon(cursor: CGPoint, cfg: BehaviorConfig) {
        switch phase {
        case .hidden:
            body = CatBody(position: edgePoint(from: cursor, in: stage.cursorScreen, cfg: cfg),
                           heading: 0)
            alpha = 1
            enter(.hunting, cursor: cursor, cfg: cfg)
        case .exiting:
            alpha = 1
            enter(.hunting, cursor: cursor, cfg: cfg)
        default:
            break
        }
    }

    private func goHome() {
        // 已在退場路上就不做事：goHome 會重設 alpha 並依當前位置重算 exitTarget，
        // 所以每帧重複 dismiss 會讓淡出永遠不完成、貓一路走出畫面。
        // Command 的文件宣稱 dismiss 幂等，這個守衛讓那句話成真。
        guard phase.isVisible, phase != .exiting else { return }
        teaserEnabled = false
        pendingExit = false
        spotlightArmed = false
        exitTarget = edgePoint(from: body.position, in: stage.union, cfg: config.config)
        alpha = 1
        enter(.exiting, cursor: body.position, cfg: config.config)
    }

    private func setTeaser(_ on: Bool, cursor: CGPoint, cfg: BehaviorConfig) {
        if on {
            // 不可用時什麼都不做；回報 TEASER_UNAVAILABLE 是 ControlUseCase（M3）的職責。
            guard catalog.capabilities.teaserAvailable else { return }
            guard !teaserEnabled else { return }
            teaserEnabled = true
            // 關掉再開時 pendingExit 可能還 latch 著（enter 只在進入 teaser phase
            // 時消費它，而重新開啟時 phase 往往沒變、enter 直接 return）。
            // 不清掉的話，下一次真正的 teaser 轉換會把貓送回家。
            pendingExit = false
            spotlightArmed = false
            spotlightOpacity = 0
            if phase == .hidden {
                body = CatBody(position: edgePoint(from: cursor, in: stage.cursorScreen, cfg: cfg),
                               heading: 0)
                alpha = 1
            }
            enter(.teaserApproach, cursor: cursor, cfg: cfg)
        } else {
            guard teaserEnabled else { return }
            teaserEnabled = false
            // spec 第 3.2 節：走完當前動作後回家
            pendingExit = true
        }
    }

    // MARK: - 每帧推進

    private func advance(dt: TimeInterval, cursor: CGPoint, cfg: BehaviorConfig) {
        phaseElapsed += dt
        actionElapsed += dt

        if phase == .hidden {
            spotlightOpacity = 0
        } else {
            updateSpotlight(dt: dt, fadingIn: phase == .hunting, cfg: cfg)
        }

        let distance = hypot(cursor.x - body.position.x, cursor.y - body.position.y)
        let arriveRadius = cfg.arriveRadius(logicalHeight: catalog.logicalHeight)

        switch phase {
        case .hidden:
            break

        case .hunting:
            move(toward: cursor, dt: dt, speed: cfg.catSpeed, cfg: cfg)
            if distance <= arriveRadius {
                enter(has(.brake) ? .arriving : .sitting, cursor: cursor, cfg: cfg)
            }

        case .arriving:
            if clipFinished(.brake) { enter(.sitting, cursor: cursor, cfg: cfg) }

        case .sitting:
            if clipFinished(.sit) { enter(.resting, cursor: cursor, cfg: cfg) }

        case .resting:
            restTimer += dt
            if distance > cfg.rehuntThreshold {
                restartHunt(cursor: cursor, cfg: cfg)
            } else if restTimer >= cfg.restDuration {
                enter(has(.lieDown) ? .lyingDown : .sleeping, cursor: cursor, cfg: cfg)
            } else {
                updateFlourish(dt: dt)
            }

        case .lyingDown:
            if clipFinished(.lieDown) { enter(.sleeping, cursor: cursor, cfg: cfg) }

        case .sleeping:
            sleepTimer += dt
            if distance > cfg.wakeThreshold {
                restartHunt(cursor: cursor, cfg: cfg)
            } else if sleepTimer >= cfg.sleepDuration {
                goHome()
            }

        case .exiting:
            move(toward: exitTarget, dt: dt, speed: cfg.catSpeed, cfg: cfg)
            alpha = max(0, alpha - CGFloat(dt / Timings.exitFade))
            if alpha <= 0 { enter(.hidden, cursor: cursor, cfg: cfg) }

        case .teaserApproach:
            move(toward: cursor, dt: dt, speed: cfg.catSpeed, cfg: cfg)
            if distance <= cfg.teaserStalkRange {
                enter(.teaserStalking, cursor: cursor, cfg: cfg)
            }

        case .teaserStalking:
            move(toward: cursor, dt: dt,
                 speed: cfg.catSpeed * Timings.stalkSpeedFactor, cfg: cfg)
            if cursorSpeed > cfg.teaserPounceTriggerSpeed || phaseElapsed >= cfg.teaserStalkTimeout {
                enter(.teaserWindup, cursor: cursor, cfg: cfg)
            }

        case .teaserWindup:
            if phaseElapsed >= Timings.windup {
                // spec 第 4.5 節：鎖定此刻的鼠標位置。
                // 之後 teaserPouncing 只讀 pounceTarget，絕不讀 cursor——
                // ballisticStep 每次呼叫都重新瞄準，換成 live cursor 就變成追蹤。
                pounceTarget = cursor
                enter(.teaserPouncing, cursor: cursor, cfg: cfg)
            }

        case .teaserPouncing:
            let result = Kinematics.ballisticStep(body: body, target: pounceTarget,
                                                  dt: dt, speed: cfg.teaserPounceSpeed)
            body = result.body
            if result.reached {
                // 比的是「貓實際落在哪」與鼠標的距離，不是鎖定點與鼠標的距離。
                // 用鎖定點會讓判定與飛行路徑脫鉤：把 target 換成 live cursor
                // （撲擊變成追蹤）時，貓明明落在鼠標上卻仍被判成撲空，
                // 而且那個改動不會讓任何測試轉紅。
                let missed = hypot(cursor.x - body.position.x,
                                   cursor.y - body.position.y) > cfg.teaserHitRadius
                enter(missed ? .teaserRetreating : .teaserTumbling, cursor: cursor, cfg: cfg)
            }

        case .teaserTumbling:
            if clipFinished(.tumble) {
                enter(.teaserRetreating, cursor: cursor, cfg: cfg)
            }

        case .teaserRetreating:
            move(toward: retreatPoint, dt: dt,
                 speed: cfg.catSpeed * Timings.retreatSpeedFactor, cfg: cfg)
            let arrivedAtRetreat = hypot(retreatPoint.x - body.position.x,
                                         retreatPoint.y - body.position.y) < 4
            if clipFinished(.retreat) || arrivedAtRetreat {
                enter(.teaserStalking, cursor: cursor, cfg: cfg)
            }
        }

        syncAction()
    }

    private func restartHunt(cursor: CGPoint, cfg: BehaviorConfig) {
        restTimer = 0
        sleepTimer = 0
        // 不需要清 activeFlourish：action(for: .hunting) 一律回 .run，
        // 而回到 resting 只能經過 enter(.resting)，那裡會清。
        // 曾經有一行 activeFlourish = nil 在這裡，它讀起來像是「立刻放棄休息動作」
        // 這條規則的執行點，但實際執行點是 action(for:) 加上無條件的重新狩獵分支。
        enter(.hunting, cursor: cursor, cfg: cfg)
    }

    private func enter(_ newPhase: CatPhase, cursor: CGPoint, cfg: BehaviorConfig) {
        guard newPhase != phase else { return }

        // 逗貓棒模式被關掉後，下一次階段轉換就回家
        if pendingExit, newPhase.isTeaser {
            pendingExit = false
            goHome()
            return
        }

        let previous = phase
        phase = newPhase
        phaseElapsed = 0
        actionElapsed = 0

        switch newPhase {
        case .hunting:
            armSpotlight(fromHidden: previous == .hidden || previous == .exiting, cfg: cfg)
        case .resting:
            restTimer = 0
            activeFlourish = nil
            flourishTimer = 0
            flourishInterval = randomizer.double(in: Timings.flourishInterval)
        case .sleeping:
            sleepTimer = 0
        case .teaserRetreating:
            retreatPoint = retreatDestination(from: cursor, cfg: cfg)
        case .hidden:
            alpha = 1
            spotlightOpacity = 0
            // 不清掉的話，status --json 會對一隻不存在的貓回報 restTimer=10
            restTimer = 0
            sleepTimer = 0
        default:
            break
        }

        syncAction()
    }

    private func syncAction() {
        let next = action(for: phase)
        if next != currentAction {
            currentAction = next
            actionElapsed = 0
        }
    }

    private func action(for phase: CatPhase) -> CatAction {
        switch phase {
        case .hidden: return .sitIdle
        case .hunting, .exiting, .teaserApproach: return .run
        case .arriving: return .brake
        case .sitting: return .sit
        case .resting: return activeFlourish ?? .sitIdle
        case .lyingDown: return .lieDown
        case .sleeping: return .sleep
        case .teaserStalking: return .stalk
        case .teaserWindup: return .windup
        case .teaserPouncing: return .pounce
        case .teaserTumbling: return .tumble
        case .teaserRetreating: return .retreat
        }
    }

    // MARK: - 休息池

    private func updateFlourish(dt: TimeInterval) {
        if let current = activeFlourish {
            if clipFinished(current) {
                activeFlourish = nil
                flourishTimer = 0
                flourishInterval = randomizer.double(in: Timings.flourishInterval)
            }
            return
        }
        flourishTimer += dt
        guard flourishTimer >= flourishInterval else { return }
        flourishTimer = 0
        activeFlourish = randomizer.pick(catalog.capabilities.restPool)
    }

    // MARK: - spotlight

    private func armSpotlight(fromHidden: Bool, cfg: BehaviorConfig) {
        guard cfg.spotlightEnabled, !teaserEnabled else {
            spotlightArmed = false
            return
        }
        switch cfg.spotlightTrigger {
        case .onSummonOnly: spotlightArmed = fromHidden
        case .everyHunt: spotlightArmed = true
        }
    }

    private func updateSpotlight(dt: TimeInterval, fadingIn: Bool, cfg: BehaviorConfig) {
        let target: CGFloat = (fadingIn && spotlightArmed) ? cfg.spotlightDimOpacity : 0
        let duration = target > spotlightOpacity ? Timings.spotlightFadeIn : Timings.spotlightFadeOut
        let amount = cfg.spotlightDimOpacity * CGFloat(dt / duration)
        if target > spotlightOpacity {
            spotlightOpacity = min(target, spotlightOpacity + amount)
        } else {
            spotlightOpacity = max(target, spotlightOpacity - amount)
        }
    }

    // MARK: - 幾何

    private func move(toward target: CGPoint, dt: TimeInterval, speed: CGFloat, cfg: BehaviorConfig) {
        body = Kinematics.step(body: body, target: target, dt: dt,
                               speed: speed, turnRateDegreesPerSecond: cfg.catTurnRate)
    }

    /// 退開的目標點：從貓的當前位置朝遠離鼠標的方向走 teaserRetreatDistance。
    ///
    /// **已知限制（M1 不修，因為在純邏輯層看不出來）：** 命中時貓的落點正好等於
    /// 鼠標（鼠標靜止時必然如此，而那是最常見的情況），此時 dx = dy = 0，
    /// 方向向量退化成 (0, 0)、retreatPoint 等於貓自己。貓不會卡住——`move(toward:)`
    /// 內部是 `atan2(0, 0) = 0`，所以牠會以退開速度往**正右方**漂——但那個方向與
    /// 牠撲擊過來的方向完全無關。等 M2 把動畫畫上去才看得出來對不對；
    /// 現在不改，是因為改成「沿原路退回」需要一個能釘住方向的測試，
    /// 而退開只持續 0.2 秒、轉向速率上限讓 180 度反轉做不完，那個測試不好寫。
    private func retreatDestination(from cursor: CGPoint, cfg: BehaviorConfig) -> CGPoint {
        let dx = body.position.x - cursor.x
        let dy = body.position.y - cursor.y
        let separation = max(hypot(dx, dy), 0.001)
        let ux = dx / separation
        let uy = dy / separation
        return CGPoint(x: body.position.x + ux * cfg.teaserRetreatDistance,
                       y: body.position.y + uy * cfg.teaserRetreatDistance)
    }

    /// 離 point 最近的邊緣外側一個貓身的位置。入場與退場共用。
    private func edgePoint(from point: CGPoint, in rect: CGRect, cfg: BehaviorConfig) -> CGPoint {
        let inset = cfg.effectiveHeight(logicalHeight: catalog.logicalHeight)
        let toLeft = point.x - rect.minX
        let toRight = rect.maxX - point.x
        let toBottom = point.y - rect.minY
        let toTop = rect.maxY - point.y
        let nearest = min(toLeft, toRight, toBottom, toTop)

        if nearest == toLeft { return CGPoint(x: rect.minX - inset, y: point.y) }
        if nearest == toRight { return CGPoint(x: rect.maxX + inset, y: point.y) }
        if nearest == toBottom { return CGPoint(x: point.x, y: rect.minY - inset) }
        return CGPoint(x: point.x, y: rect.maxY + inset)
    }

    // MARK: - 素材查詢

    private func has(_ action: CatAction) -> Bool {
        catalog.capabilities.available.contains(action)
    }

    /// 缺這個動作時視為已播完 —— 降級的入口。
    private func clipFinished(_ action: CatAction) -> Bool {
        guard let clip = catalog.clip(for: action) else { return true }
        return actionElapsed >= clip.duration
    }

    private func frameIndex(for action: CatAction) -> (index: Int, count: Int) {
        guard let clip = catalog.clip(for: action), clip.frames > 0 else { return (0, 1) }
        let raw = Int(actionElapsed * clip.fps)
        if clip.loops { return (raw % clip.frames, clip.frames) }
        return (min(raw, clip.frames - 1), clip.frames)
    }

    // MARK: - 輸出

    private func makeState(cursor: CGPoint, cfg: BehaviorConfig) -> CatFrameState {
        let (index, count) = frameIndex(for: currentAction)
        let spotlight: SpotlightState = spotlightOpacity > 0
            ? SpotlightState(
                center: cursor,
                radius: SpotlightGeometry.radius(
                    cursor: cursor, cat: body.position,
                    effectiveHeight: cfg.effectiveHeight(logicalHeight: catalog.logicalHeight),
                    margin: cfg.spotlightMargin),
                opacity: spotlightOpacity)
            : .inactive

        return CatFrameState(
            phase: phase, phaseElapsed: phaseElapsed, body: body,
            action: currentAction, frameIndex: index, frameCount: count, alpha: alpha,
            spotlight: spotlight, cursor: cursor,
            teaserEnabled: teaserEnabled,
            teaserAvailable: catalog.capabilities.teaserAvailable,
            restTimer: restTimer, sleepTimer: sleepTimer)
    }

    private func updateCursorSpeed(cursor: CGPoint, dt: TimeInterval) {
        if let previous = previousCursor, dt > 0 {
            cursorSpeed = hypot(cursor.x - previous.x, cursor.y - previous.y) / CGFloat(dt)
        } else {
            cursorSpeed = 0
        }
        previousCursor = cursor
    }

    /// Task 14 使用
    var currentCursorSpeed: CGFloat { cursorSpeed }
}
