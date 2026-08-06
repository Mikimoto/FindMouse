import Foundation

/// `findmouse status --json` 的 `data`。spec 第 8.4 節。
///
/// **座標系一律是 AppKit 全域座標：原點在主螢幕左下，Y 向上。**
/// macOS 同時存在原點左上的事件座標系，不明寫一定會有人（包括 AI）算錯。
public struct StatusPayload: Codable, Sendable, Equatable {

    public struct Point: Codable, Sendable, Equatable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public struct Teaser: Codable, Sendable, Equatable {
        public let enabled: Bool
        public let available: Bool
        public init(enabled: Bool, available: Bool) {
            self.enabled = enabled; self.available = available
        }
    }

    public struct Cat: Codable, Sendable, Equatable {
        public let position: Point
        /// "left" 或 "right"
        public let facing: String
        public let action: String
        public let frame: Int
        public let frameCount: Int
        public init(position: Point, facing: String, action: String,
                    frame: Int, frameCount: Int) {
            self.position = position; self.facing = facing; self.action = action
            self.frame = frame; self.frameCount = frameCount
        }
    }

    public struct Spotlight: Codable, Sendable, Equatable {
        public let active: Bool
        public let radius: Double
        public let opacity: Double
        public init(active: Bool, radius: Double, opacity: Double) {
            self.active = active; self.radius = radius; self.opacity = opacity
        }
    }

    public struct Timers: Codable, Sendable, Equatable {
        public let rest: Double
        public let sleep: Double
        public init(rest: Double, sleep: Double) { self.rest = rest; self.sleep = sleep }
    }

    public struct Pack: Codable, Sendable, Equatable {
        public let id: String
        public let logicalHeight: Double
        public init(id: String, logicalHeight: Double) {
            self.id = id; self.logicalHeight = logicalHeight
        }
    }

    /// `screenIndex` 是**鼠標所在**螢幕在 `NSScreen.screens` 中的索引。
    /// 貓與鼠標可能在不同螢幕上，這個欄位一律以鼠標為準（spec 第 8.4 節）。
    public struct Display: Codable, Sendable, Equatable {
        public let screenIndex: Int
        public let scale: Double
        public init(screenIndex: Int, scale: Double) {
            self.screenIndex = screenIndex; self.scale = scale
        }
    }

    public let appVersion: String
    public let visible: Bool
    public let phase: String
    public let phaseElapsed: Double
    public let teaser: Teaser
    public let cat: Cat
    public let cursor: Point
    public let distance: Double
    public let spotlight: Spotlight
    public let timers: Timers
    public let pack: Pack
    public let display: Display

    public init(appVersion: String, visible: Bool, phase: String, phaseElapsed: Double,
                teaser: Teaser, cat: Cat, cursor: Point, distance: Double,
                spotlight: Spotlight, timers: Timers, pack: Pack, display: Display) {
        self.appVersion = appVersion; self.visible = visible
        self.phase = phase; self.phaseElapsed = phaseElapsed
        self.teaser = teaser; self.cat = cat; self.cursor = cursor
        self.distance = distance; self.spotlight = spotlight
        self.timers = timers; self.pack = pack; self.display = display
    }
}
