import Darwin
import Foundation

/// 連上 control socket、送一行 JSON、收一行 JSON。
///
/// 為什麼住在 `FindMouseWire` 而不是 Adapters：CLI 只依賴 Wire（spec 第 8.5 節），
/// 而測試也要一個 client。放這裡，CLI、單元測試、e2e 腳本走的是**同一份**
/// 連線邏輯——尤其是「連不上 = App 沒在跑」那個判定，它是 exit code 3 的唯一依據，
/// 有兩份實作就會有兩種判法。
public enum WireClient {

    public enum ClientError: Error, Equatable {
        /// `connect` 回 ENOENT／ECONNREFUSED：沒有人在聽。這就是 APP_NOT_RUNNING。
        case appNotRunning
        case pathTooLong(String)
        case connectionFailed(errno: Int32)
        /// 連上了但對方沒回東西就關了連線
        case noResponse
    }

    /// 送出請求並讀回一整行回應（不含換行）。
    public static func send(_ request: WireRequest, to path: String) throws -> Data {
        let fd = try connect(to: path)
        defer { close(fd) }

        var line = try JSONEncoder().encode(request)
        line.append(UInt8(ascii: "\n"))
        SocketLine.write(fd, line)
        // 寫完就關掉寫端：對方讀到 EOF 才知道請求結束，
        // 不然雙方會各自等對方先說話。
        shutdown(fd, SHUT_WR)

        guard let response = SocketLine.read(fd), !response.isEmpty else {
            throw ClientError.noResponse
        }
        return response
    }

    /// 有沒有人在這個路徑上聽。
    ///
    /// **判定方式是真的 connect，不是看檔案在不在。** App 啟動時先 unlink 再 bind
    /// （spec 第 8.1 節），所以殘留的 socket 檔一直都在，檔案存在證明不了任何事。
    public static func isListening(at path: String) -> Bool {
        guard let fd = try? connect(to: path) else { return false }
        close(fd)
        return true
    }

    private static func connect(to path: String) throws -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { throw ClientError.pathTooLong(path) }
        SocketLine.fill(&addr, with: path, capacity: capacity)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.connectionFailed(errno: errno) }

        // 收訊逾時。沒有它的話，App 若卡在主執行緒（或 accept 迴圈死了但
        // listening socket 還開著），`findmouse status` 會**永遠**掛在那裡——
        // 一個沒有輸出、沒有 exit code、Ctrl-C 之外無法結束的命令。
        // 逾時之後 read 回 EAGAIN，SocketLine.read 回 nil，於是 send 丟 noResponse。
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

        var stored = addr
        let result = withUnsafePointer(to: &stored) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            // 三種都是「App 沒在跑」，只是路徑上留下的東西不同：
            //   ENOENT       檔案不在
            //   ECONNREFUSED 上次崩潰留下的 socket 檔，沒人 accept
            //   ENOTSOCK     路徑上是個普通檔案。App 若在跑，start() 早就把它
            //                unlink 掉並換成 socket 了，所以它同樣證明沒人在跑
            // 分不開對使用者沒有意義，而 exit code 3 要的正是這個判定。
            throw [ENOENT, ECONNREFUSED, ENOTSOCK].contains(code)
                ? ClientError.appNotRunning
                : ClientError.connectionFailed(errno: code)
        }
        return fd
    }
}

/// client 與 server 共用的低階讀寫。分出來是因為兩邊的 bug 形狀一樣：
/// `write` 可能只寫一部分、`read` 可能被訊號打斷。
///
/// public 是為了讓 server（住在 Adapters）用同一份，而不是各寫一次。
public enum SocketLine {

    /// 單一請求的上限。沒有上限的話，一個不送換行的 client 可以讓
    /// server 執行緒一路把記憶體吃光。
    public static let maxBytes = 1 << 20

    public static func fill(_ addr: inout sockaddr_un, with path: String, capacity: Int) {
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                _ = strncpy(dst, path, capacity - 1)
            }
        }
    }

    /// 讀到換行或 EOF 為止。回 nil 表示讀失敗（不是空行）。
    ///
    /// 一次讀一個 byte。請求都是幾百 bytes 的 JSON，緩衝的複雜度換不到東西，
    /// 而「緩衝區裡跨行殘留的資料」正是這種程式碼最經典的 bug。
    public static func read(_ fd: Int32) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < maxBytes {
            let n = Darwin.read(fd, &byte, 1)
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if byte == UInt8(ascii: "\n") { break }
            data.append(byte)
        }
        return data
    }

    /// **這個迴圈沒有測試涵蓋，而且是刻意留著的。**
    ///
    /// mutation 實測：把它改成「只寫第一次的量」全部測試照樣綠。原因不是測試不夠，
    /// 是阻塞式 stream socket 的 `write` 依 POSIX 只有在**被訊號打斷**時才會短寫，
    /// 而測試裡沒有訊號。要構造它得送真的 signal，那個測試本身的脆弱度高過它守住的東西。
    /// 留著是因為短寫一旦發生就是靜默截斷一段 JSON——收到的那端只會說「解不開」。
    public static func write(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    return
                }
                sent += n
            }
        }
    }
}
