import FindMouseDomain
import FindMouseCore

final class StubConfig: ConfigProviderPort, @unchecked Sendable {
    var value: BehaviorConfig

    init(_ value: BehaviorConfig = BehaviorConfig()) {
        self.value = value
    }

    var config: BehaviorConfig { value }
}
