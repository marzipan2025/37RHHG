// 다른 앱 창들의 위치를 0.25초마다 한 줄로 내보내는 도우미.
// 형식: "ox,oy|x,y,w,h;x,y,w,h;..."  (모두 pt, 화면 좌표는 주 화면 왼쪽 위 기준)
// ox,oy 는 모든 화면을 합친 영역의 왼쪽 위. Godot의 화면 좌표는 여기를 원점으로 한다.
// 첫 인자로 부모(캐릭터 앱) pid를 받아 그 앱의 창은 빼고, 부모가 끝나면 같이 끝난다.
import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let parent = Int32(CommandLine.arguments.dropFirst().first ?? "") ?? getppid()

func origin() -> CGPoint {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    var o = CGPoint(x: CGFloat.greatestFiniteMagnitude, y: CGFloat.greatestFiniteMagnitude)
    for id in ids {
        let b = CGDisplayBounds(id)
        o.x = min(o.x, b.minX)
        o.y = min(o.y, b.minY)
    }
    return count > 0 ? o : .zero
}

while true {
    if kill(parent, 0) != 0 { exit(0) }
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var rects: [String] = []
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != parent,
              let b = w[kCGWindowBounds as String] as? [String: Any] else { continue }
        if let a = w[kCGWindowAlpha as String] as? Double, a < 0.1 { continue }
        let x = (b["X"] as? Double) ?? 0, y = (b["Y"] as? Double) ?? 0
        let ww = (b["Width"] as? Double) ?? 0, hh = (b["Height"] as? Double) ?? 0
        if ww < 120 || hh < 80 { continue }
        rects.append(String(format: "%.0f,%.0f,%.0f,%.0f", x, y, ww, hh))
    }
    let o = origin()
    print(String(format: "%.0f,%.0f|", o.x, o.y) + rects.joined(separator: ";"))
    usleep(250_000)
}
