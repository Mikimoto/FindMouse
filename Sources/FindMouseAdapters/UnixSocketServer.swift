import Foundation
import FindMouseWire

/// control socket 的生命週期與 JSONL 收發（spec 第 8.1、8.2 節）。
///
/// 一行一個 JSON，request → response → 關閉連線。無狀態，所以不需要處理
/// 「同一條連線上第二個請求」——每個 CLI 命令自己連一次。
///
/// 這一層**只管傳輸**：解出 `WireRequest` 之後就交給注入的 handler
/// （`RequestRouter`），所以命令語意不在這裡測。
public final class UnixSocketServer: @unchecked Sendable {

    public enum StartError: Error, Equatable {
        case pathTooLong(String)
        case cannotCreateSocket(errno: Int32)
        case cannotBind(errno: Int32)
        case cannotListen(errno: Int32)
    }

    /// `~/Library/Application Support/FindMouse/control.sock`
    public static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("FindMouse/control.sock").path
    }

    private let path: String
    private let handle: @Sendable (WireRequest) -> Data
    private let lock = NSLock()
    private var listenFD: Int32 = -1

    /// - Parameter handle: 收到請求時呼叫。**它會在 accept 執行緒上被呼叫**，
    ///   所以碰到 App 狀態的實作必須自己切回 main actor（見 AppDelegate）。
    public init(path: String, handle: @escaping @Sendable (WireRequest) -> Data) {
        self.path = path
        self.handle = handle
    }

    public func start() throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { throw StartError.pathTooLong(path) }
        SocketLine.fill(&addr, with: path, capacity: capacity)

        // 目錄權限 0700 是 socket 那個 0600 的**前提**，不是額外的保險。
        //
        // `bind` 依 umask 建檔（實測 umask 022 → srwxr-xr-x），我們要到下面
        // 才 chmod 成 0600——中間那段時間 socket 本身是 world-connectable。
        // 目錄鎖成 0700 之後，那個窗口裡別的使用者也走不進來。
        // 只驗 socket 的權限看不到這件事：e2e 量的是 chmod 之後的狀態。
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // 目錄可能是舊版留下的（那時建成 0755），所以每次都收緊一次。
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: directory.path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.cannotCreateSocket(errno: errno) }

        // 先 unlink 再 bind：上次崩潰留下的 stale socket 檔不能擋住啟動（spec 第 8.1 節）。
        // 代價是「檔案存不存在」從此不能拿來判斷有沒有第二個實例——那要真的 connect。
        unlink(path)

        var stored = addr
        let bound = withUnsafePointer(to: &stored) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw StartError.cannotBind(errno: code)
        }

        // 0600：只有本使用者能控制。bind 之後才有檔案可以 chmod。
        chmod(path, 0o600)

        guard listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw StartError.cannotListen(errno: code)
        }

        lock.lock()
        listenFD = fd
        lock.unlock()

        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "com.findmouse.socket"
        thread.start()
    }

    public func stop() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        guard fd >= 0 else { return }
        // shutdown 讓阻塞中的 accept 立刻回來；單靠 close 在某些狀況下不會喚醒它。
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(path)
    }

    // MARK: - accept 迴圈

    /// 這個迴圈**絕對不能因為單一連線出錯而結束**。
    ///
    /// 它一旦靜默結束，之後每個 CLI 命令都會回 APP_NOT_RUNNING，
    /// 而 App 的畫面看起來完全正常——是本 task 最貴的失敗模式。
    /// 所以每個 client 的處理都自己吞掉錯誤，而 accept 只在
    /// 「server 已被 stop」時才離開。
    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return   // fd 被 stop() 關掉了，或監聽 socket 真的壞了
            }
            serve(client)
            close(client)
        }
    }

    private func serve(_ client: Int32) {
        // CLI 提早斷線時，write 會送出 SIGPIPE 把整個 App 殺掉。
        // SO_NOSIGPIPE 讓它退化成 EPIPE，由 SocketLine.write 自己處理。
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        guard let line = SocketLine.read(client), !line.isEmpty else { return }

        var response: Data
        if let request = try? JSONDecoder().decode(WireRequest.self, from: line) {
            response = handle(request)
        } else {
            // 解不開的 JSON 是 client 的用法錯誤（exit 2），不是 App 的故障。
            // 由這一層回，因為 handler 收的是已經解好的 WireRequest。
            response = Self.malformed
        }
        response.append(UInt8(ascii: "\n"))
        SocketLine.write(client, response)
    }

    private static let malformed = (try? JSONEncoder().encode(
        WireResponse<AckPayload>(error: WireError(
            code: .invalidArgument, message: "請求不是合法的 JSON"))))
        ?? Data(#"{"protocol":1,"ok":false,"error":{"code":"INVALID_ARGUMENT","message":"bad json"}}"#.utf8)
}
