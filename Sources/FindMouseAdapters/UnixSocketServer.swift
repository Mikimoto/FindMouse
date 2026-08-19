// Copyright 2026 Mikimoto
// SPDX-License-Identifier: Apache-2.0

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

    /// 沙盒容器 `Data` 根底下的 `control.sock`，可用 `FINDMOUSE_SOCKET` 覆寫。
    /// 定義在 `FindMouseWire`，與 CLI 共用同一份——**同一個屬性，不是兩份算法**，
    /// 所以兩端不可能錯開。
    public static var defaultPath: String { ControlSocket.path }

    private let path: String
    private let handle: @Sendable (WireRequest) -> Data
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var acceptLoopAlive = false

    /// accept 迴圈還在不在。**只給測試用。**
    ///
    /// 沒有這個縫，「`stop()` 之後迴圈要結束」就沒有任何測試釘得住——
    /// 讓 EBADF 也 continue 的話，每個停掉的 server 都留下一條每 100ms 醒一次的
    /// 執行緒，而它手上那個 fd 編號可能已經被別的 socket 重用了。
    var isAcceptLoopRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return acceptLoopAlive
    }

    /// - Parameter handle: 收到請求時呼叫。**它會在 accept 執行緒上被呼叫**，
    ///   所以碰到 App 狀態的實作必須自己切回 main actor（見 AppDelegate）。
    public init(path: String, handle: @escaping @Sendable (WireRequest) -> Data) {
        self.path = path
        self.handle = handle
    }

    public func start() throws {
        // 對端消失時的 write 會用 SIGPIPE 殺掉整個 App（實測）。
        // 見 SocketLine.ignoreSIGPIPE：SO_NOSIGPIPE 在那個情況下設不起來。
        SocketLine.ignoreSIGPIPE()

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
        // `createDirectory` 在沙盒下是 no-op——容器由 containermanagerd 建好了。
        // 它真的會動的是兩種情況：非沙盒建置（那時它造出一個沒人管的假容器，
        // 讓那件事有聲音的是 `AppDelegate` 那道 `isInOwnContainer` 檢查），
        // 以及 `FINDMOUSE_SOCKET` 指到一個還不存在的深層路徑（e2e 就是那樣用的）。
        //
        // 收緊那一行在沙盒下也是 no-op：實測本機 849 個容器的 `Data` **全部**
        // 都是 700（755 的那 4 個是容器根，不是 `Data`）。留著是因為它是 socket
        // 那個 0600 的前提，而「系統一定會給 700」沒有任何文件保證——更何況
        // 覆寫路徑那個目錄是我們自己建的，它只跟著 umask。
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
        lock.lock(); acceptLoopAlive = true; lock.unlock()
        defer { lock.lock(); acceptLoopAlive = false; lock.unlock() }
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                let code = errno
                // 只有「監聽 socket 沒了」才離開，其餘一律續跑。
                //
                // 原本寫成「除了 EINTR 都 return」，那讓一堆**暫時性**的 errno
                // 變成永久停業：ECONNABORTED（對端在 accept 完成前就跑了）、
                // EMFILE／ENFILE（fd 一時用完，本 App 會開 PNG）、ENOMEM／ENOBUFS。
                // 這個迴圈一旦靜默結束，App 畫面完全正常而每個 CLI 命令都回
                // APP_NOT_RUNNING——本檔開頭那段註解說的正是不能發生這件事。
                if code == EBADF || code == EINVAL || code == ENOTSOCK {
                    return   // stop() 關掉了 fd，這是唯一該離開的理由
                }
                // 其餘一律退讓 100ms 再試。不分辨個別 errno 是刻意的：
                // 白名單漏掉的那個會變成永久停業，而**任何**未知且持續的錯誤
                // 若直接 continue 就是 100% CPU 的空轉。退讓讓兩種都只是變慢。
                usleep(100_000)
                continue
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

        // 讀取逾時。server 只有一條 accept 執行緒，而 serve 是在它上面同步跑的，
        // 所以**一個連上來卻不說話的 client 會讓整個控制介面停擺**：其餘命令全部
        // 逾時、CLI 回 APP_NOT_RUNNING（exit 3），而 App 其實好好的。
        // client 端早就有 5 秒逾時（WireClient），server 端沒有是不對稱的漏洞。
        //
        // 而且 server 的逾時要**比 client 短**。設成一樣的 5 秒時，沉默的 client
        // 佔住 accept 執行緒的那 5 秒剛好等於後面那個 client 的耐心，兩個計時器
        // 同時到期——實測是個會偶爾紅的競賽。短一點，等待中的 client 才會拿到
        // 真正的回應，而不是自己的逾時。
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

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
