import Foundation

/// 回應信封。payload 用泛型而不是任意 JSON——欄位名進型別系統，
/// 之後重構才不會默默改掉 AI 正在依賴的欄位（spec 第 7.1 節的理由）。
public struct WireResponse<Payload: Codable & Sendable>: Codable, Sendable {
    public let protocolVersion: Int
    public let ok: Bool
    public let data: Payload?
    public let error: WireError?

    public init(data: Payload) {
        self.protocolVersion = WireProtocol.version
        self.ok = true
        self.data = data
        self.error = nil
    }

    public init(error: WireError) {
        self.protocolVersion = WireProtocol.version
        self.ok = false
        self.data = nil
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case ok, data, error
    }
}
