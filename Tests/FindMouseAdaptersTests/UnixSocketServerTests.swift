import Foundation
import Testing
@testable import FindMouseAdapters
import FindMouseWire

/// 每個測試用自己的暫存路徑，避免互相干擾也避免污染真實的 control.sock。
///
/// 放 `/tmp` 而不是 `NSTemporaryDirectory()`：後者在沙盒外也可能長到
/// 一百多個字元，而 `sun_path` 只有 104 bytes——路徑太長會讓每個測試
/// 都因為 `pathTooLong` 失敗，而那個原因與被測的東西無關。
private func tempSocketPath() -> String {
    "/tmp/fm-test-\(UUID().uuidString.prefix(8)).sock"
}

/// 回一個固定 ack，把「命令語意」排除在這個檔案之外——那是 RequestRouter 的測試。
private func echoServer(at path: String) -> UnixSocketServer {
    UnixSocketServer(path: path) { request in
        (try? JSONEncoder().encode(WireResponse(data: AckPayload(queued: request.command))))
            ?? Data()
    }
}

private func ack(_ data: Data) throws -> AckPayload {
    try #require(try JSONDecoder().decode(WireResponse<AckPayload>.self, from: data).data)
}

@Test func requestGetsARoundTripResponse() throws {
    let path = tempSocketPath()
    let server = echoServer(at: path)
    try server.start()
    defer { server.stop() }

    let response = try WireClient.send(WireRequest(command: "summon"), to: path)
    #expect(try ack(response).queued == "summon")
}

/// spec 第 8.1 節：權限 0600，只有本使用者能控制。
@Test func socketFileIsCreatedWith0600() throws {
    let path = tempSocketPath()
    let server = echoServer(at: path)
    try server.start()
    defer { server.stop() }

    let mode = try #require(
        try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
    #expect(mode.int16Value == 0o600, "實際是 \(String(mode.intValue, radix: 8))")
}

/// socket 的 0600 只有在**目錄也關起來**時才是完整的保證。
///
/// `bind` 依 umask 建檔（umask 022 → srwxr-xr-x），我們要到下一行才 chmod 成
/// 0600——中間那段時間 socket 本身是 world-connectable。只驗 socket 權限看不到
/// 這個窗口，因為量到的是 chmod 之後的狀態。目錄鎖成 0700 就從構造上關掉它。
///
/// 夾具刻意先把目錄設成 0755：舊版留下的目錄就是那個權限，而「只在建立時設對」
/// 的實作會讓已經存在的目錄永遠停在 0755。
@Test func socketDirectoryIsTightenedEvenIfItAlreadyExists() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fm-perm-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o755])
    defer { try? FileManager.default.removeItem(at: dir) }

    let server = echoServer(at: dir.appendingPathComponent("control.sock").path)
    try server.start()
    defer { server.stop() }

    let mode = try #require(
        try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)
    #expect(mode.int16Value == 0o700, "目錄還是 \(String(mode.intValue, radix: 8))")
}

/// 上次崩潰留下的檔案不能擋住啟動。
@Test func staleSocketFileDoesNotBlockStartup() throws {
    let path = tempSocketPath()
    // 先手動放一個同名的普通檔案——bind 對已存在的路徑會回 EADDRINUSE
    try Data("上次崩潰留下的".utf8).write(to: URL(fileURLWithPath: path))
    #expect(FileManager.default.fileExists(atPath: path))

    let server = echoServer(at: path)
    try server.start()
    defer { server.stop() }

    #expect(try ack(try WireClient.send(WireRequest(command: "status"), to: path)).queued
            == "status")
}

/// 第二個實例的偵測要靠**連得上**，不能靠檔案存不存在。
///
/// 因為 `start()` 會先 unlink，殘留的 socket 檔一直都在——
/// 用檔案存在與否來判斷，第二個實例會直接把第一個的 socket 搶走，
/// 而第一個 App 從此對 CLI 隱形，畫面卻完全正常。
@Test func detectsAnotherInstanceByConnectingNotByFileExistence() throws {
    let path = tempSocketPath()
    #expect(WireClient.isListening(at: path) == false)

    let server = echoServer(at: path)
    try server.start()
    #expect(WireClient.isListening(at: path) == true)

    server.stop()
    #expect(WireClient.isListening(at: path) == false, "stop 之後不該還有人在聽")

    // 關鍵的一半：留下檔案但沒有人在聽時，「檔案存在」必須不等於「有實例」
    try Data().write(to: URL(fileURLWithPath: path))
    #expect(FileManager.default.fileExists(atPath: path))
    #expect(WireClient.isListening(at: path) == false,
            "只看檔案存不存在的話，這裡會誤判成已有實例在跑")
    try? FileManager.default.removeItem(atPath: path)
}

/// 一行一個 JSON：兩個請求分兩次連線，不是同一條連線上兩行。
///
/// 順帶證明 accept 迴圈跑得下去——只服務一次就結束的 server 會讓
/// 第二次連線一直卡著。
@Test func eachConnectionHandlesExactlyOneRequest() throws {
    let path = tempSocketPath()
    let server = echoServer(at: path)
    try server.start()
    defer { server.stop() }

    for command in ["summon", "dismiss", "toggle", "status"] {
        #expect(try ack(try WireClient.send(WireRequest(command: command), to: path)).queued
                == command)
    }
}

/// 壞掉的 JSON 不能讓 server 執行緒死掉——之後的請求還要能服務。
///
/// **這是本檔最重要的一條。** accept 迴圈一旦靜默結束，之後每個 CLI 命令都會
/// 回 APP_NOT_RUNNING，而 App 看起來完全正常，沒有任何地方會報錯。
@Test func malformedRequestDoesNotKillTheServer() throws {
    let path = tempSocketPath()
    let server = echoServer(at: path)
    try server.start()
    defer { server.stop() }

    for junk in ["{ not json", "", "[]", "{\"protocol\":1}", String(repeating: "x", count: 5000)] {
        _ = try? rawSend(junk, to: path)
    }

    // 收拾完垃圾之後，正常請求仍然要通
    #expect(try ack(try WireClient.send(WireRequest(command: "summon"), to: path)).queued
            == "summon")
}

/// 解不開的 JSON 要回 INVALID_ARGUMENT，而不是靜默關掉連線。
///
/// 靜默關掉的話 CLI 拿到的是「連上了但沒有回應」，那個訊息會把人指向
/// 網路問題，而真正的原因是自己送了壞掉的請求。
@Test func malformedRequestGetsAnInvalidArgumentResponse() throws {
    let path = tempSocketPath()
    let server = echoServer(at: path)
    try server.start()
    defer { server.stop() }

    let raw = try rawSend("{ not json", to: path)
    let response = try JSONDecoder().decode(WireResponse<AckPayload>.self, from: raw)
    #expect(response.ok == false)
    #expect(response.error?.code == .invalidArgument)
    #expect(response.error?.code.exitCode == 2)
}

/// App 沒在跑時 client 要回 appNotRunning——那是 exit code 3 的唯一依據。
@Test func connectingToNothingReportsAppNotRunning() {
    #expect(throws: WireClient.ClientError.appNotRunning) {
        try WireClient.send(WireRequest(command: "status"), to: tempSocketPath())
    }
}

/// 路徑上留下東西的兩種情況都算「App 沒在跑」。
///
/// 這兩者的 errno **不一樣**（實測：殘留 socket 是 ECONNREFUSED 61，
/// 普通檔案是 ENOTSOCK 38），所以只認其中一個的實作會在另一種情況下
/// 回一個帶 errno 的技術性錯誤，CLI 的 exit code 就從 3 變成 1，
/// 而腳本的「App 沒開就啟動它」那條分支從此不會觸發。
@Test func leftoversAtThePathStillReportAppNotRunning() throws {
    // 真正的崩潰殘留：bind 過、沒 unlink、沒人 accept
    let stale = tempSocketPath()
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    SocketLine.fill(&addr, with: stale, capacity: MemoryLayout.size(ofValue: addr.sun_path))
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(fd >= 0)
    var stored = addr
    let bound = withUnsafePointer(to: &stored) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    try #require(bound == 0)
    close(fd)
    defer { try? FileManager.default.removeItem(atPath: stale) }
    #expect(FileManager.default.fileExists(atPath: stale))

    #expect(throws: WireClient.ClientError.appNotRunning) {
        try WireClient.send(WireRequest(command: "status"), to: stale)
    }

    // 路徑上是個普通檔案（有人手動放的、或別的程式佔用）
    let junk = tempSocketPath()
    try Data("不是 socket".utf8).write(to: URL(fileURLWithPath: junk))
    defer { try? FileManager.default.removeItem(atPath: junk) }

    #expect(throws: WireClient.ClientError.appNotRunning) {
        try WireClient.send(WireRequest(command: "status"), to: junk)
    }
    #expect(WireClient.isListening(at: junk) == false)
}

/// 不經過 `WireClient` 直接送原始位元組，用來餵它不肯產生的壞資料。
private func rawSend(_ text: String, to path: String) throws -> Data {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    SocketLine.fill(&addr, with: path, capacity: capacity)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(fd >= 0)
    defer { close(fd) }

    // 逾時與 `WireClient` 一樣不可省。少了它，任何讓 server 不回應的 mutation
    // 都不是「測試轉紅」而是「整個 test run 永遠掛住」——實測過一次，
    // 跑了十分鐘才發現卡在這裡。
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var stored = addr
    let connected = withUnsafePointer(to: &stored) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    try #require(connected == 0)

    SocketLine.write(fd, Data((text + "\n").utf8))
    shutdown(fd, SHUT_WR)
    return SocketLine.read(fd) ?? Data()
}
