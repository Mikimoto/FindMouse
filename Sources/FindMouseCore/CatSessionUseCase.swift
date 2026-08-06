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
    /// 上一帧的舞台。只有在它變動時才需要檢查貓有沒有被留在畫面外。
    private var previousStage: Stage?

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

        relocateIfStageShrankAwayFromTheCat(previous: previousStage, cfg: cfg)
        previousStage = stage
        updateCursorSpeed(cursor: cursor, dt: dt)
        for command in commands {
            apply(command, cursor: cursor, cfg: cfg)
        }
        advance(dt: dt, cursor: cursor, cfg: cfg)
        return makeState(cursor: cursor, cfg: cfg)
    }

    /// 螢幕組態變更後，貓可能停在一個已經不存在的座標上（spec 第 10 節）。
    ///
    /// 不搬的話它仍然在追鼠標，於是從畫面外慢慢走回來——使用者看到的是
    /// 「按了快捷鍵，好幾秒都沒有貓」，看起來像卡住而不像降級。
    ///
    /// **只在舞台真的變動的那一帧檢查。** 每帧都檢查是錯的：貓在 `hunting`
    /// 剛入場與 `exiting` 走出去時**本來就在畫面外**（`edgePoint` 刻意把牠放在
    /// 邊緣外側），每帧夾一次會把整段進場動畫變成瞬移。實測會讓 M1 的三條
    /// dt 相關測試一起轉紅——那些測試斷言的正是「貓在這一帧只能移動這麼多」。
    ///
    /// 搬到 `cursorScreen` 而不是 `union` 裡最近的點：union 是所有螢幕的**外接矩形**，
    /// 螢幕錯位排列時它涵蓋的空隙不屬於任何一片，夾進去仍然看不見。
    /// cursorScreen 一定是真的存在的一片，而且就是使用者正在看的那片。
    private func relocateIfStageShrankAwayFromTheCat(previous: Stage?, cfg: BehaviorConfig) {
        guard let previous, previous != stage,
              phase.isVisible,
              !stage.cursorScreen.isEmpty,
              !stage.union.contains(body.position) else { return }

        // 留半隻貓的邊距。夾到 maxX 剛好會讓貓站在邊界上——一半在畫面外，
        // 而且 `CGRect.contains` 對邊界點回 false，所以「搬回來了」這件事
        // 連斷言都寫不出來。螢幕比貓還小的話邊距退化成一半，不讓矩形翻過來。
        let half = catalog.logicalHeight * cfg.catScale / 2
        let screen = stage.cursorScreen
        let margin = min(half, min(screen.width, screen.height) / 2)
        let inset = screen.insetBy(dx: margin, dy: margin)
        body.position = CGPoint(
            x: min(max(body.position.x, inset.minX), inset.maxX),
            y: min(max(body.position.y, inset.minY), inset.maxY))
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
            // 停止距離就是 stalkRange：進到潛行範圍之後不再靠近，只轉向跟隨鼠標。
            //
            // spec 第 4.5 節說「撲空正是逗貓棒的全部樂趣；會追蹤的撲擊等於百發百中」，
            // 但沒有停止距離的話貓會一路走到鼠標腳邊（135 px/s 走 3 秒 = 405 px，
            // 而 stalkRange 只有 250），實測貼到 2.08 px，撲擊只飛 1 帧——撲空需要
            // 鼠標達 3600 px/s，結構上不可能。停在 250 px 上，撲擊飛 0.114 秒，
            // 撲空門檻降到 528 px/s，剛好在撲擊觸發速度 400 px/s 之上：快到足以
            // 觸發撲擊的甩動，就有實際機會閃過。
            //
            // speed 0 讓 Kinematics.step 只轉不走（step = speed × dt = 0），
            // 所以「朝向跟隨鼠標」仍然成立。
            move(toward: cursor, dt: dt,
                 speed: distance > cfg.teaserStalkRange
                     ? cfg.catSpeed * Timings.stalkSpeedFactor : 0,
                 cfg: cfg)
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

    /// **`!teaserEnabled` 目前餵不到輸入，是刻意留下的防禦。**
    /// 這個函式只從 `enter(.hunting)` 呼叫，而不變式「`teaserEnabled` 為真時
    /// phase 必為 teaser 階段」讓那件事在 M1 不可能發生：`summon` 對 teaser 階段
    /// 是 no-op，`toggle` 先走 `goHome()` 而它第一件事就是清掉 `teaserEnabled`，
    /// `restartHunt` 只從 resting／sleeping 呼叫而那兩個 phase 與 teaser 不共存。
    /// 所以把這個條件拿掉，測試會全綠——不要因此以為它被測到了。
    ///
    /// 保留它的理由是 spec 第 5.2 節要求「逗貓棒的任何階段暗幕都是 0」，而真正
    /// 在執行那條規則的是 `updateSpotlight(fadingIn: phase == .hunting)` 加上這個
    /// 不變式，不是這個條件。M2 若新增一條「teaser 開著也能進 hunting」的路徑，
    /// `teaserEnabledImpliesTeaserPhase` 會轉紅，屆時這個條件就變成 load-bearing。
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
    /// 撲空路徑上這個方向是受測的：`retreatMovesStraightAwayFromCursorAfterAMiss`
    /// 讓貓撲過頭（鼠標落在落點後方 70 px），此時「遠離鼠標」與貓的 heading 一致、
    /// 不需轉向，貓直線走完退開全程 117 px，把方向釘住。
    ///
    /// **已知限制（M1 不修）：命中且鼠標靜止時，退開方向不受控。**
    /// 那種命中（最常見的情況）落點正好等於鼠標，dx = dy = 0，方向向量退化，
    /// retreatPoint 等於貓自己的位置。貓不會卡住，但實際軌跡與「遠離鼠標」無關：
    ///
    /// - 第一帧 `move(toward:)` 的 desired 是 `atan2(0, 0) = 0`，所以貓朝 +x 轉 9°
    ///   （540°/s 的每帧上限）並前進 9 px，於是離開了 retreatPoint。
    /// - 之後 retreatPoint 落在貓身後，每帧所需轉向都貼在 ±π 邊界上，正負號由浮點
    ///   捨入決定：實測既出現「延續第一帧的轉向」也出現「反向」，不是設計出來的。
    /// - 退開共 13 帧（clip 0.2 s，浮點讓第 12 帧差一點沒到），每帧都用掉整個 9°
    ///   上限、總共轉 117°，所以路徑是一段弧。貓實際飛過的 13 個 heading 恰好構成
    ///   一組間隔 9°、跨度 108° 的方向（只有順序不同），因此淨位移長度是常數：
    ///   實測八個鼠標位置都是 97.8058873608 px，方向與撲擊方向剛好相差
    ///   ±45° 或 ±63°。
    ///
    /// 也就是說貓大致沿著撲擊方向繼續走、路徑彎成一段弧，最後停在離鼠標 97.8 px
    /// 的地方（不是設定的 150 px）。距離上仍算退開了，方向上不算。等 M2 把動畫畫
    /// 上去才判得出這樣看起來對不對，所以現在不動行為。
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
