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
        let dt = min(max(rawDt, 0), Timings.maxTickDelta)
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
        guard phase.isVisible else { return }
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

        case .teaserApproach, .teaserStalking, .teaserWindup,
             .teaserPouncing, .teaserTumbling, .teaserRetreating:
            break   // Task 14 補完
        }

        syncAction()
    }

    private func restartHunt(cursor: CGPoint, cfg: BehaviorConfig) {
        restTimer = 0
        sleepTimer = 0
        activeFlourish = nil
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
        case .hidden:
            alpha = 1
            spotlightOpacity = 0
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
