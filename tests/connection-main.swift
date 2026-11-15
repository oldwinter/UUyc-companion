import Foundation
@main struct ConnectionTests {
 static func main() {
  let t = Date(timeIntervalSince1970: 100)
  var s = UUConnectionState()
  precondition(s.update(overlay: false, controllers: [], now: t) == nil)
  precondition(s.update(overlay: false, controllers: ["OPPO Find N2"], now: t) == .connected)
  precondition(s.update(overlay: false, controllers: ["OPPO Find N2"], now: t.addingTimeInterval(1)) == nil)
  precondition(s.update(overlay: false, controllers: [], now: t.addingTimeInterval(2)) == nil)
  precondition(s.update(overlay: false, controllers: [], now: t.addingTimeInterval(2.6)) == .disconnected)
  precondition(s.update(overlay: true, controllers: nil, now: t.addingTimeInterval(3)) == .connected)
  precondition(s.update(overlay: true, controllers: ["iPhone 17"], now: t.addingTimeInterval(3.5)) == .controllerChanged)
  precondition(s.update(overlay: true, controllers: ["OPPO Find N2"], now: t.addingTimeInterval(4)) == .controllerChanged)
  precondition(s.update(overlay: false, controllers: nil, now: t.addingTimeInterval(5)) == nil)
  precondition(s.update(overlay: false, controllers: nil, now: t.addingTimeInterval(5.6)) == .disconnected)
  precondition(s.update(overlay: false, controllers: nil, now: t.addingTimeInterval(7)) == nil)
  // 权限缺失/主窗口关闭：仅覆盖窗口仍能确认连接。
  var fallback = UUConnectionState()
  precondition(fallback.update(overlay: false, controllers: nil, now: t) == nil)
  precondition(fallback.update(overlay: true, controllers: nil, now: t) == .connected)
  precondition(fallback.update(overlay: false, controllers: nil, now: t.addingTimeInterval(1.5)) == nil)
  precondition(fallback.update(overlay: false, controllers: nil, now: t.addingTimeInterval(1.51)) == .disconnected)
  precondition(fallback.update(overlay: false, controllers: ["OPPO Find N2"], now: t.addingTimeInterval(2)) == .connected)
  // 明确无人控制的表格不应单独触发；覆盖窗口存在时仍保留旧路径。
  var idle = UUConnectionState()
  for i in 0..<1000 {
   precondition(idle.update(overlay: false, controllers: [], now: t.addingTimeInterval(Double(i))) == nil)
  }
  precondition(idle.update(overlay: true, controllers: [], now: t.addingTimeInterval(1000)) == .connected)
  precondition(idle.controller == nil)

  // 慢 AX 缓存兜底：中间瞬时 nil 只要不超过 1.5s 不应触发断开抖动。
  var stable = UUConnectionState()
  precondition(stable.update(overlay: false, controllers: ["vivo X Fold6"], now: t) == .connected)
  precondition(stable.controller == "vivo X Fold6")
  precondition(stable.update(overlay: false, controllers: nil, now: t.addingTimeInterval(1.2)) == nil)
  precondition(stable.update(overlay: false, controllers: ["vivo X Fold6"], now: t.addingTimeInterval(1.6)) == nil)
  precondition(stable.connected)
  precondition(stable.controller == "vivo X Fold6")
  print("PASS: Android without overlay, unchanged session, debounce, delayed name, device switch, disconnect, no-flap")
 }
}
