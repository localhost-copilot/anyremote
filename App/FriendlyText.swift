import Foundation

/// User-facing wording for messages that come from the wire (in English) or
/// from the system.
enum FriendlyText {
    static func message(_ raw: String) -> String {
        let table: [(String, String)] = [
            ("pairing code is not valid", "配对码不对。请核对那台 Mac 上 AnyRemote › 设置 里显示的配对码。"),
            ("authentication failed", "配对码不对。请核对那台 Mac 上 AnyRemote › 设置 里显示的配对码。"),
            ("being controlled by", "那台 Mac 正被其他人控制。"),
            ("Remote control is turned off", "那台 Mac 关闭了「允许其他 Mac 控制」。"),
            ("Remote control was turned off", "那台 Mac 关闭了「允许其他 Mac 控制」。"),
            ("incompatible AnyRemote version", "两台 Mac 上的 AnyRemote 版本不一致，请装同一个版本。"),
            ("took over this Mac", "另一台 Mac 接管了控制。"),
            ("The host ended the session", "对方在那台 Mac 上断开了连接。"),
            ("did not respond", "那台 Mac 没有响应。确认它已开机、AnyRemote 在运行，并且在同一网络。"),
            ("Connection refused", "连不上：那台 Mac 上 AnyRemote 没在运行，或者端口被防火墙挡住了。"),
            ("connection was closed", "连接被关闭了。"),
            ("window is no longer available", "这个窗口已经关闭了。"),
        ]
        for (needle, text) in table where raw.localizedCaseInsensitiveContains(needle) {
            if needle == "being controlled by", let range = raw.range(of: "controlled by ") {
                let holder = raw[range.upperBound...].prefix { $0 != "." }
                return "那台 Mac 正被「\(holder)」控制。"
            }
            if needle == "took over this Mac" {
                let holder = raw.components(separatedBy: " took over").first ?? ""
                return "「\(holder)」接管了这台 Mac 的控制。"
            }
            return text
        }
        return raw
    }

    static func isPairingFailure(_ raw: String) -> Bool {
        raw.localizedCaseInsensitiveContains("pairing code") || raw.localizedCaseInsensitiveContains("authentication failed")
    }

    static func isBusy(_ raw: String) -> Bool { raw.localizedCaseInsensitiveContains("being controlled") }
}
