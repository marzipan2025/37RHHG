// 말 도우미. 캐릭터의 말은 머리 위 유리 상자에, 답장 입력칸은 발치에 띄운다.
// Godot 창 밖에 그려야 해서(창은 캐릭터 크기뿐) 네이티브로 따로 뺐다. 상자는 메뉴 버튼 그림을 따른
// 둥근 사각형(캐릭터 말은 분홍, 입력칸은 베이지).
//
// 표준 입력(한 줄에 JSON 하나). 좌표는 화면 pt, 왼쪽 위 원점.
//   {"op":"say","text":"…", "x":..,"y":..,"fy":..}   머리끝 가운데 (x,y), 발 높이 fy
//   {"op":"input","mode":"reply|key", …}            발치에 입력칸
//   {"op":"move","x":..,"y":..,"fy":..}
//   {"op":"hidetext"} {"op":"hideinput"} {"op":"hide"}
//   {"op":"menu","dir":"그림 폴더","items":["ctrl","sonnet","what","hey"], "x":..,"y":..,"fy":..}  캐릭터 옆 그림 버튼 메뉴
//   {"op":"hidemenu"}
//   {"op":"scan","px":..,"py":..,"cell":16}         그 점이 있는 화면을 찍어 칸마다 복잡도를 잰다(혼자 돌아다니기용)
//   {"op":"step","px":..,"py":..,"m":[a,b,c,d]}     발자국 하나: 단위 원을 (a,b)·(c,d) 열로 옮긴 타원(pt, y 아래 +), 2초에 걸쳐 사라짐
//   {"op":"speak","text":"…"} {"op":"voiceoff"}     캐릭터의 말을 Supertonic 3 로 읽기 / 끄기(엔진도 내린다)
//   {"op":"ctx"}                                    맥과 주변 정보(일정·할 일·날씨·지금 쓰는 앱·음악 등)를 모아 돌려준다
//   {"op":"act","id":n,"name":"music|volume|open_app|open_url|add_reminder|add_event","input":{…}}  다른 앱 움직이기
// 표준 출력(한 줄씩): "over"/"out"(마우스가 글씨 위에 들어옴/나감) | "click"(글씨를 누름) | "typing"(입력칸에 처음 글을 침)
//                   | "esc"(Esc, 또는 아무것도 안 친 채 5초) | "submit <base64 글>"
//                   | "menu <버튼 이름>"(메뉴 버튼을 누름) | "menuclose"(바깥을 눌렀거나 한동안 안 써서 닫힘)
//                   | "ctx <base64 글>"(맥과 주변 정보, 한 줄에 하나씩, 한국어)
//                   | "acted <id> ok|fail <base64 한마디>"(act 결과)
//                   | "grid <열> <행> <화면 x> <화면 y> <칸 pt> <base64 busy> <base64 edge>" | "noscan"(권한 없음·실패)
// 표준 입력이 닫히면(앱이 끝나면) 같이 끝난다.
import Cocoa
import ScreenCaptureKit
import EventKit
import CoreLocation
import IOKit.ps
import AVFoundation

let textMaxW: CGFloat = 320    // 글 최대 폭(상자 안쪽)
let fontSize: CGFloat = 14     // 입력칸과 같은 크기·글꼴, 굵기만 조금 더
let textPad = NSSize(width: 14, height: 9)   // 상자 안 여백
let inputW: CGFloat = 240
let inputIdle: TimeInterval = 5.0   // 입력이 이만큼 없으면 입력칸을 닫는다(답장일 때만)

let emitLock = NSLock()
func emit(_ s: String) {
    emitLock.lock()
    FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
    emitLock.unlock()
}

// ---------------------------------------------------------------- 화면 복잡도 격자
// 화면을 작게 찍어 칸(cell pt)마다 이웃 화소끼리의 색 차이를 잰다. busy 는 평균(글자·아이콘이 많은 곳),
// edge 는 최댓값(경계선). 찍은 그림은 저장하지 않고 숫자만 넘긴다. 이 앱 자신과 Godot 창은 빼고 찍는다.
let scanSub = 8                 // 칸 하나를 이만큼의 화소로 본다
var scanAsked = false
var scanBusy = false

func scan(at p: CGPoint, cell: CGFloat) {
    guard #available(macOS 14.0, *) else { emit("noscan"); return }
    if !CGPreflightScreenCaptureAccess() {
        if !scanAsked { scanAsked = true; CGRequestScreenCaptureAccess() }
        emit("noscan")
        return
    }
    if scanBusy { return }
    scanBusy = true
    Task {
        defer { scanBusy = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let disp = content.displays.first(where: { $0.frame.contains(p) }) ?? content.displays.first else {
                emit("noscan"); return
            }
            let mine = content.applications.filter { $0.processID == getpid() || $0.processID == getppid() }
            let filter = SCContentFilter(display: disp, excludingApplications: mine, exceptingWindows: [])
            let cols = Int(disp.frame.width / cell), rows = Int(disp.frame.height / cell)
            let cfg = SCStreamConfiguration()
            cfg.width = cols * scanSub
            cfg.height = rows * scanSub
            cfg.showsCursor = false
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            let (busy, edge) = measure(img, cols: cols, rows: rows)
            let f = disp.frame
            emit("grid \(cols) \(rows) \(f.minX) \(f.minY) \(cell) \(busy.base64EncodedString()) \(edge.base64EncodedString())")
        } catch {
            emit("noscan")
        }
    }
}

func measure(_ img: CGImage, cols: Int, rows: Int) -> (Data, Data) {
    let w = cols * scanSub, h = rows * scanSub
    var px = [UInt8](repeating: 0, count: w * h * 4)
    px.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    // 화소마다 오른쪽·아래 이웃과의 가장 큰 채널 차이(0~255)
    func diff(_ a: Int, _ b: Int) -> Int {
        max(abs(Int(px[a]) - Int(px[b])), abs(Int(px[a + 1]) - Int(px[b + 1])), abs(Int(px[a + 2]) - Int(px[b + 2])))
    }
    var busy = Data(count: cols * rows), edge = Data(count: cols * rows)
    for cy in 0..<rows {
        for cx in 0..<cols {
            var sum = 0, mx = 0
            for y in cy * scanSub..<(cy + 1) * scanSub {
                for x in cx * scanSub..<(cx + 1) * scanSub {
                    let i = (y * w + x) * 4
                    var d = 0
                    if x + 1 < w { d = diff(i, i + 4) }
                    if y + 1 < h { d = max(d, diff(i, i + w * 4)) }
                    sum += d
                    mx = max(mx, d)
                }
            }
            let mean = sum / (scanSub * scanSub)
            busy[cy * cols + cx] = UInt8(min(255, mean * 4))
            edge[cy * cols + cx] = UInt8(mx)
        }
    }
    return (busy, edge)
}

// 유리 상자 안의 말. 글씨 색은 시스템 글자색이라 라이트/다크 모드를 저절로 따른다.
// ---------------------------------------------------------------- 말풍선·입력칸 상자
// 메뉴 버튼 그림을 둥근 사각형으로 옮긴 모양: 진한 테두리, 위가 밝은 세로 그러데이션,
// 안쪽 밝은 테두리, 왼쪽 위 작은 광택. 색은 버튼 그림에서 잰 값.
struct Candy {
    let border, top, mid, bottom, rim, text, hint: NSColor
    static func c(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
    // 캐릭터의 말: 분홍(Walk!·Sonnet 버튼)
    static let pink = Candy(border: c(210, 102, 115), top: c(254, 203, 212), mid: c(253, 183, 194), bottom: c(247, 156, 162),
                            rim: c(255, 222, 228), text: c(184, 70, 86), hint: c(214, 120, 132))
    // 내 입력칸: 베이지(What?·Hey! 버튼)
    static let beige = Candy(border: c(192, 158, 142), top: c(253, 240, 229), mid: c(244, 227, 214), bottom: c(234, 213, 198),
                             rim: c(255, 250, 244), text: c(122, 88, 74), hint: c(196, 160, 143))
}

// 창 그림자는 가장자리에 검은 선이 생겨서 끄고, 상자 둘레 여백(boxPad)에 버튼처럼 옅은 그림자를 직접 그린다.
let boxPad: CGFloat = 6

final class CandyBox: NSView {
    var candy: Candy { didSet { needsDisplay = true } }
    let radius: CGFloat = 14
    let content: NSView

    init(_ candy: Candy, content: NSView) {
        self.candy = candy
        self.content = content
        super.init(frame: .zero)
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError() }

    // 안쪽 내용 크기를 받아 상자(여백 포함) 크기로 맞춘다.
    func fit(_ inner: NSSize) -> NSSize {
        let s = NSSize(width: inner.width + boxPad * 2, height: inner.height + boxPad * 2)
        frame = NSRect(origin: .zero, size: s)
        content.frame = NSRect(x: boxPad, y: boxPad, width: inner.width, height: inner.height)
        needsDisplay = true
        return s
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds.insetBy(dx: boxPad, dy: boxPad)
        let rad = min(radius, b.height / 2)
        // 테두리(+ 아래로 옅은 그림자)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.2)
        sh.shadowBlurRadius = 3.5
        sh.shadowOffset = NSSize(width: 0, height: -1.5)
        sh.set()
        candy.border.setFill()
        NSBezierPath(roundedRect: b, xRadius: rad, yRadius: rad).fill()
        NSGraphicsContext.restoreGraphicsState()
        // 몸통: 위가 밝은 그러데이션
        let inner = b.insetBy(dx: 1.5, dy: 1.5)
        let body = NSBezierPath(roundedRect: inner, xRadius: rad - 1.5, yRadius: rad - 1.5)
        NSGradient(colors: [candy.bottom, candy.mid, candy.top], atLocations: [0, 0.5, 1], colorSpace: .sRGB)?
            .draw(in: body, angle: 90)
        // 안쪽 밝은 테두리
        let rimR = inner.insetBy(dx: 1, dy: 1)
        let rim = NSBezierPath(roundedRect: rimR, xRadius: rad - 2.5, yRadius: rad - 2.5)
        rim.lineWidth = 1
        candy.rim.withAlphaComponent(0.8).setStroke()
        rim.stroke()
        // 왼쪽 위 광택: 기운 작은 타원
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: inner.minX + rad * 0.75, yBy: inner.maxY - 5.5)
        t.rotate(byDegrees: 20)
        t.concat()
        let gloss = NSBezierPath(ovalIn: NSRect(x: -7, y: -2.5, width: 14, height: 5))
        NSGradient(starting: NSColor.white.withAlphaComponent(0.95), ending: NSColor.white.withAlphaComponent(0.35))?
            .draw(in: gloss, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class TextView: NSView {
    var text = ""
    let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)

    func attrs() -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.lineSpacing = 2
        p.lineBreakStrategy = .hangulWordPriority   // 한국어도 낱말 단위로 줄을 바꾼다
        return [.font: font, .paragraphStyle: p, .foregroundColor: Candy.pink.text]
    }

    // 재는 것과 그리는 것을 같은 레이아웃으로 해서 줄바꿈이 어긋나 글이 잘리는 일이 없게 한다.
    var storage = NSTextStorage()
    let lm = NSLayoutManager()
    let tc = NSTextContainer(size: NSSize(width: textMaxW, height: 100000))

    override init(frame: NSRect) {
        super.init(frame: frame)
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
    }
    required init?(coder: NSCoder) { fatalError() }

    // 상자 크기(여백 포함). 짧은 말은 상자도 좁게.
    func fit() -> NSSize {
        storage.removeLayoutManager(lm)
        storage = NSTextStorage(string: text, attributes: attrs())
        storage.addLayoutManager(lm)
        lm.ensureLayout(for: tc)
        let r = lm.usedRect(for: tc)
        return NSSize(width: ceil(r.width) + textPad.width * 2, height: ceil(r.height) + textPad.height * 2)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        storage.addAttributes(attrs(), range: NSRange(location: 0, length: storage.length))
        lm.drawGlyphs(forGlyphRange: lm.glyphRange(for: tc), at: NSPoint(x: textPad.width, y: textPad.height))
    }
    // 마우스가 글씨 위에 있는 동안은 앱이 사라지는 타이머를 멈춘다.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { emit("over") }
    override func mouseExited(with event: NSEvent) { emit("out") }
    override func mouseDown(with event: NSEvent) { emit("click") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class InputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // 메뉴가 없는 도우미라 ⌘V 등이 저절로 되지 않는다. 직접 넘겨 준다.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if e.type == .keyDown, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let ch = e.charactersIgnoringModifiers {
            let sel: Selector? = ["v": #selector(NSText.paste(_:)), "c": #selector(NSText.copy(_:)),
                                  "x": #selector(NSText.cut(_:)), "a": #selector(NSText.selectAll(_:))][ch]
            if let sel, NSApp.sendAction(sel, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: e)
    }
    override func cancelOperation(_ sender: Any?) { emit("esc") }
    // 한글 조합 중에는 글이 바뀐 알림이 늦을 수 있어서, 키를 누르는 것 자체도 입력 시작으로 본다.
    var onKey: (() -> Void)?
    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown, e.keyCode != 53 { onKey?() }
        super.sendEvent(e)
    }
}

// ---------------------------------------------------------------- 캐릭터 옆 그림 버튼 메뉴
let menuBtn = NSSize(width: 75, height: 75.0 * 100.0 / 292.0)   // 버튼 그림(292×100)을 이 크기(pt)로
let menuGap: CGFloat = 6
let menuPad: CGFloat = 10       // 커지는 버튼과 그림자가 잘리지 않게 두는 둘레 여백
let menuOffset: CGFloat = 57    // 캐릭터 가운데에서 버튼 가장자리까지
let menuIdleTime: TimeInterval = 8.0
let menuShift: CGFloat = 4      // 버튼을 아래로, 캐릭터 반대쪽으로 조금 더 띄운다

// 그림 버튼. 상태 표시는 모든 버튼이 같다: 올리면 조금 커지고 밝아지며 그림자가 짙어지고,
// 누르면 조금 작아지고 어두워지며 그림자가 얕아진다.
final class ImageButton: NSView {
    let name: String
    let img = CALayer()
    let shade = CALayer()
    var hover = false
    var down = false
    var onClick: ((String) -> Void)?

    init(name: String, image: CGImage, frame: NSRect) {
        self.name = name
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        img.frame = bounds
        img.contents = image
        img.contentsGravity = .resizeAspect
        img.shadowColor = NSColor.black.cgColor
        img.shadowOffset = CGSize(width: 0, height: -1.5)
        let mask = CALayer()
        mask.frame = bounds
        mask.contents = image
        mask.contentsGravity = .resizeAspect
        shade.frame = bounds
        shade.mask = mask
        shade.opacity = 0
        img.addSublayer(shade)
        layer?.addSublayer(img)
        img.opacity = 0
        refresh(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh(animated: Bool = true) {
        let s: CGFloat = down ? 0.95 : (hover ? 1.06 : 1.0)
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? (down ? 0.06 : 0.14) : 0)
        img.transform = CATransform3DMakeScale(s, s, 1)
        shade.backgroundColor = (down ? NSColor.black : NSColor.white).cgColor
        shade.opacity = down ? 0.12 : (hover ? 0.22 : 0)
        img.shadowOpacity = down ? 0.10 : (hover ? 0.32 : 0.18)
        img.shadowRadius = down ? 1.5 : (hover ? 5 : 3)
        CATransaction.commit()
    }

    // 뜰 때: 작고 투명한 데서 제자리로.
    func pop(after delay: TimeInterval) {
        img.transform = CATransform3DMakeScale(0.85, 0.85, 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.16)
            self.img.opacity = 1
            CATransaction.commit()
            self.refresh()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover = true; refresh() }
    override func mouseExited(with event: NSEvent) { hover = false; down = false; refresh() }
    override func mouseDown(with event: NSEvent) { down = true; refresh() }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        down = false
        refresh()
        if inside { onClick?(name) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

func makePanel<T: NSPanel>(_ type: T.Type, shadow: Bool) -> T {
    let p = T(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = shadow
    p.level = .statusBar
    p.hidesOnDeactivate = false
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    return p
}

final class Talk: NSObject, NSTextFieldDelegate {
    let textPanel = makePanel(NSPanel.self, shadow: false)
    let textView = TextView()
    let inputPanel = makePanel(InputPanel.self, shadow: false)
    let inputBox = NSView()
    var field: NSTextField = NSTextField()
    var head = CGPoint.zero
    var feetY: CGFloat = 0
    var idle: Timer?
    var idleOn = false
    var typed = false
    var prevApp: NSRunningApplication?
    let menuPanel = makePanel(NSPanel.self, shadow: false)
    lazy var textBox = CandyBox(.pink, content: textView)
    lazy var inputCandy = CandyBox(.beige, content: inputBox)
    var menuIdle: Timer?
    var menuMonitor: Any?

    override init() {
        super.init()
        textPanel.contentView = textBox
        inputPanel.contentView = inputCandy
        inputPanel.onKey = { [weak self] in self?.startTyping() }
    }

    // 왼쪽 위 원점 → Cocoa 좌표(아래가 원점)
    func cocoa(_ p: CGPoint) -> NSPoint {
        NSPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
    }
    func visible(_ p: NSPoint) -> NSRect {
        (NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.screens.first)?.visibleFrame ?? .zero
    }

    func place() {
        let a = cocoa(head)
        let vis = visible(a)
        if textPanel.isVisible {
            // 머리 위 가운데. 화면 밖으로 나가면 안쪽으로 민다.
            let s = textPanel.frame.size
            var o = NSPoint(x: a.x - s.width / 2, y: a.y + 6 - boxPad)
            o.y = min(o.y, vis.maxY - s.height)
            o.x = max(vis.minX, min(o.x, vis.maxX - s.width))
            textPanel.setFrameOrigin(o)
        }
        if menuPanel.isVisible {
            // 머리끝 높이에서 아래로, 캐릭터 오른쪽(자리가 없으면 왼쪽).
            let s = menuPanel.frame.size
            var o = NSPoint(x: a.x + menuOffset + menuShift - menuPad, y: a.y - 14 - menuShift + menuPad - s.height)
            if o.x + s.width - menuPad > vis.maxX {
                o.x = a.x - menuOffset - menuShift - menuBtn.width - menuPad
            }
            o.y = max(vis.minY, min(o.y, vis.maxY - s.height))
            menuPanel.setFrameOrigin(o)
        }
        if inputPanel.isVisible {
            // 발치 가운데. 화면 아래로 나가면 화면 안에 걸친다.
            let s = inputPanel.frame.size
            let f = cocoa(CGPoint(x: head.x, y: feetY))
            var o = NSPoint(x: f.x - s.width / 2, y: f.y - 6 - s.height + boxPad)
            o.y = max(o.y, vis.minY + 4)
            o.x = max(vis.minX, min(o.x, vis.maxX - s.width))
            inputPanel.setFrameOrigin(o)
        }
    }

    // 캐릭터 옆에 그림 버튼을 세로로 띄운다. 오른쪽에 자리가 없으면 왼쪽에.
    func showMenu(dir: String, items: [String]) {
        hideMenu()
        let n = CGFloat(items.count)
        let size = NSSize(width: menuBtn.width + menuPad * 2,
                          height: n * menuBtn.height + (n - 1) * menuGap + menuPad * 2)
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        var y = size.height - menuPad - menuBtn.height
        for (i, name) in items.enumerated() {
            guard let im = NSImage(contentsOfFile: dir + "/btn_" + name + ".png"),
                  let cg = im.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let b = ImageButton(name: name, image: cg, frame: NSRect(x: menuPad, y: y, width: menuBtn.width, height: menuBtn.height))
            b.onClick = { [weak self] name in
                self?.hideMenu()
                emit("menu " + name)
            }
            content.addSubview(b)
            b.pop(after: Double(i) * 0.035)
            y -= menuBtn.height + menuGap
        }
        menuPanel.setContentSize(size)
        menuPanel.contentView = content
        menuPanel.orderFrontRegardless()
        place()
        // 바깥을 누르면 닫는다. 캐릭터 위를 누른 것은 Godot 쪽이 처리하니 여기서는 두기.
        menuMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            let p = NSEvent.mouseLocation
            let top = self.cocoa(self.head), bottom = self.cocoa(CGPoint(x: self.head.x, y: self.feetY))
            let body = NSRect(x: top.x - 50, y: bottom.y - 8, width: 100, height: top.y - bottom.y + 16)
            if body.contains(p) { return }
            self.hideMenu()
            emit("menuclose")
        }
        menuIdle = Timer.scheduledTimer(withTimeInterval: menuIdleTime, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.menuPanel.frame.contains(NSEvent.mouseLocation) { return }
            self.hideMenu()
            emit("menuclose")
        }
    }

    func hideMenu() {
        menuIdle?.invalidate()
        menuIdle = nil
        if let m = menuMonitor { NSEvent.removeMonitor(m) }
        menuMonitor = nil
        menuPanel.orderOut(nil)
    }

    func say(_ text: String) {
        textView.text = text
        let s = textBox.fit(textView.fit())
        textPanel.setContentSize(s)
        textView.needsDisplay = true
        textPanel.orderFrontRegardless()
        place()
        // 뜨는 자리에 마우스가 이미 있으면 들어왔다는 알림이 오지 않으므로 직접 알린다.
        emit(textPanel.frame.contains(NSEvent.mouseLocation) ? "over" : "out")
        // 확인용: BUBBLE_DUMP=경로 를 주면 글씨 그림을 회색 바탕 PNG 로 남긴다.
        if let path = ProcessInfo.processInfo.environment["BUBBLE_DUMP"],
           let rep = textView.bitmapImageRepForCachingDisplay(in: textView.bounds) {
            textView.cacheDisplay(in: textView.bounds, to: rep)
            let img = NSImage(size: textView.bounds.size)
            img.lockFocus()
            NSColor(white: 0.55, alpha: 1).setFill()
            NSRect(origin: .zero, size: textView.bounds.size).fill()
            rep.draw(in: textView.bounds)
            img.unlockFocus()
            if let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t) {
                try? b.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    func input(mode: String) {
        field.removeFromSuperview()
        field = mode == "key" ? NSSecureTextField() : NSTextField()
        field.font = .systemFont(ofSize: 14)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = Candy.beige.text
        field.placeholderAttributedString = NSAttributedString(
            string: mode == "key" ? "키를 붙여 넣고 Enter" : "답장 쓰고 Enter",
            attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: Candy.beige.hint])
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        let size = NSSize(width: inputW, height: 36)
        inputPanel.setContentSize(inputCandy.fit(size))
        field.frame = NSRect(x: 12, y: 8, width: size.width - 24, height: 20)
        inputBox.addSubview(field)
        // 입력칸은 키보드를 가져간다. 닫을 때 원래 쓰던 앱에 돌려주려고 기억해 둔다.
        if !inputPanel.isVisible {
            let front = NSWorkspace.shared.frontmostApplication
            prevApp = front?.processIdentifier == getpid() ? nil : front
        }
        inputPanel.makeKeyAndOrderFront(nil)
        inputPanel.makeFirstResponder(field)
        place()
        idleOn = mode != "key"
        typed = false
        touch()
    }

    // 글을 치기 시작하면 Esc 나 Enter 전까지 입력칸을 닫지 않는다.
    func startTyping() {
        if typed { return }
        typed = true
        idleOn = false
        touch()
        emit("typing")
    }

    // 입력칸을 열 때 5초 타이머를 건다(글을 치기 시작하면 끈다).
    func touch() {
        idle?.invalidate()
        idle = nil
        if idleOn {
            idle = Timer.scheduledTimer(withTimeInterval: inputIdle, repeats: false) { _ in emit("esc") }
        }
    }

    func hideInput() {
        idle?.invalidate()
        idle = nil
        let hadKeys = inputPanel.isKeyWindow
        inputPanel.orderOut(nil)
        field.removeFromSuperview()
        // 입력칸이 키보드를 쥔 채 사라지면 원래 앱의 창이 키 입력을 못 받는 상태로 남는다.
        // 원래 앱을 다시 앞으로 불러 키보드를 돌려준다. 사용자가 이미 다른 데를 눌렀으면 건드리지 않는다.
        if hadKeys, let p = prevApp, !p.isTerminated {
            p.activate()
        }
        prevApp = nil
    }

    @objc func submit() {
        let d = field.stringValue.data(using: .utf8) ?? Data()
        emit("submit " + d.base64EncodedString())
    }

    func controlTextDidChange(_ obj: Notification) { startTyping() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            emit("esc")
            return true
        }
        return false
    }

    func handle(_ j: [String: Any]) {
        if let x = j["x"] as? Double, let y = j["y"] as? Double { head = CGPoint(x: x, y: y) }
        if let f = j["fy"] as? Double { feetY = CGFloat(f) }
        switch j["op"] as? String {
        case "say": say(j["text"] as? String ?? "")
        case "input": input(mode: j["mode"] as? String ?? "reply")
        case "move": place()
        case "hidetext": textPanel.orderOut(nil)
        case "hideinput": hideInput()
        case "hide": textPanel.orderOut(nil); hideInput()
        case "menu": showMenu(dir: j["dir"] as? String ?? "", items: j["items"] as? [String] ?? [])
        case "hidemenu": hideMenu()
        case "ctx": macContext.gather()
        case "speak": voice.speak(j["text"] as? String ?? "")
        case "voiceoff": voice.off()
        case "step":
            let m = (j["m"] as? [Double] ?? [1, 0, 0, 1]).map { CGFloat($0) }
            if m.count == 4 { prints.stamp(at: CGPoint(x: j["px"] as? Double ?? 0, y: j["py"] as? Double ?? 0), m: m) }
        case "act": macContext.act(id: j["id"] as? Int ?? 0, name: j["name"] as? String ?? "",
                                   input: j["input"] as? [String: Any] ?? [:])
        case "scan": scan(at: CGPoint(x: j["px"] as? Double ?? 0, y: j["py"] as? Double ?? 0), cell: CGFloat(j["cell"] as? Double ?? 16))
        default: break
        }
    }
}

// ---------------------------------------------------------------- 목소리
// Supertonic 3(로컬 ONNX)을 22SUTO 의 파이썬 환경으로 띄운 tts_daemon.py 가 한 줄씩 wav 로 만들고,
// 여기서 음을 높여(AVAudioUnitTimePitch, 빠르기는 그대로) 재생한다. 22SUTO 가 없는 맥에서는 조용히 넘어간다.
// 처음 켤 때 모델을 올리고(0.5초, 메모리 ~400MB), 끄면 내린다. 새 말이 오면 읽던 것은 끊고 마지막 것만 읽는다.
let voicePitch: Float = 450      // cent(100 = 반음). F1 을 여자아이처럼(300 은 낮았다).

final class Voice {
    var proc: Process?
    var input: FileHandle?
    var dead = false              // 엔진이 없다(22SUTO 없음)
    var nextId = 0
    var latest = 0
    var buf = Data()
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let pitch = AVAudioUnitTimePitch()
    var wired: AVAudioFormat?
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rhhg-voice")

    init() {
        pitch.pitch = voicePitch
        engine.attach(player)
        engine.attach(pitch)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func script() -> String? {
        if let p = Bundle.main.path(forResource: "tts_daemon", ofType: "py") { return p }
        let dev = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("tts_daemon.py").path
        return FileManager.default.fileExists(atPath: dev) ? dev : nil
    }

    func start() -> Bool {
        if proc?.isRunning == true { return true }
        let py = NSHomeDirectory() + "/Library/Application Support/22SUTO/venv/bin/python"
        guard !dead, FileManager.default.isExecutableFile(atPath: py), let sc = script() else { dead = true; return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = ["-I", sc]
        let i = Pipe(), o = Pipe()
        p.standardInput = i
        p.standardOutput = o
        p.standardError = FileHandle.nullDevice
        o.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            DispatchQueue.main.async { self?.read(d) }
        }
        do { try p.run() } catch { dead = true; return false }
        proc = p
        input = i.fileHandleForWriting
        return true
    }

    func read(_ d: Data) {
        buf.append(d)
        while let nl = buf.firstIndex(of: 10) {
            let line = String(decoding: buf[buf.startIndex..<nl], as: UTF8.self)
            buf.removeSubrange(buf.startIndex...nl)
            let f = line.split(separator: " ")
            if line == "noengine" { dead = true; off(); return }
            guard f.count == 2, let id = Int(f[1]) else { continue }
            let url = file(id)
            if f[0] == "ok" && id == latest { play(url) } else { try? FileManager.default.removeItem(at: url) }
        }
    }

    func file(_ id: Int) -> URL { dir.appendingPathComponent("\(id).wav") }

    func speak(_ text: String) {
        guard start(), let input else { return }
        nextId += 1
        latest = nextId
        player.stop()
        let j: [String: Any] = ["id": nextId, "text": text, "out": file(nextId).path]
        guard var d = try? JSONSerialization.data(withJSONObject: j) else { return }
        d.append(10)
        input.write(d)
    }

    func play(_ url: URL) {
        guard let f = try? AVAudioFile(forReading: url) else { return }
        if wired != f.processingFormat {
            engine.connect(player, to: pitch, format: f.processingFormat)
            engine.connect(pitch, to: engine.mainMixerNode, format: f.processingFormat)
            wired = f.processingFormat
        }
        if !engine.isRunning { try? engine.start() }
        player.stop()
        player.scheduleFile(f, at: nil) { try? FileManager.default.removeItem(at: url) }
        player.play()
    }

    func off() {
        player.stop()
        proc?.terminate()
        proc = nil
        input = nil
        latest = -1
        if engine.isRunning { engine.stop() }
    }
}

// ---------------------------------------------------------------- 발자국
// 화면마다 클릭이 통과하는 투명 패널 하나를 깔고, 발이 닿을 때마다 타원을 찍어 천천히(printFade 초) 지운다.
// 캐릭터 창(Godot, floating) 바로 아래 높이라 일반 앱 창보다는 위, 캐릭터보다는 아래.
let printFade: CFTimeInterval = 2.0

final class Prints {
    var panels: [NSScreen: NSPanel] = [:]

    func panel(for at: NSPoint) -> NSPanel? {
        guard let sc = NSScreen.screens.first(where: { $0.frame.contains(at) }) else { return nil }
        if let p = panels[sc], p.frame == sc.frame { return p }
        panels[sc]?.orderOut(nil)
        let p = makePanel(NSPanel.self, shadow: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        p.ignoresMouseEvents = true
        p.setFrame(sc.frame, display: false)
        let v = NSView(frame: NSRect(origin: .zero, size: sc.frame.size))
        v.wantsLayer = true
        p.contentView = v
        p.orderFrontRegardless()
        panels[sc] = p
        return p
    }

    // at: 화면 pt(왼쪽 위 원점), m: 단위 원을 화면으로 옮기는 두 열 (m0,m1)·(m2,m3), y 아래가 +
    func stamp(at: CGPoint, m: [CGFloat]) {
        let c = talk.cocoa(at)
        guard hypot(m[0], m[1]) > 0.5, let p = panel(for: c), let root = p.contentView?.layer else { return }
        let l = CAShapeLayer()
        l.path = CGPath(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2), transform: nil)
        l.fillColor = NSColor(white: 0.0, alpha: 0.11).cgColor
        l.position = CGPoint(x: c.x - p.frame.minX, y: c.y - p.frame.minY)
        // Cocoa 는 y 가 위로 + 라 y 성분을 뒤집는다.
        l.setAffineTransform(CGAffineTransform(a: m[0], b: -m[1], c: m[2], d: -m[3], tx: 0, ty: 0))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.addSublayer(l)
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.duration = printFade
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        l.opacity = 0
        l.add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + printFade + 0.1) { l.removeFromSuperlayer() }
    }
}

// ---------------------------------------------------------------- 맥과 주변 정보
// 캐릭터가 말할 거리. 사용자의 맥에서 읽기만 하고 아무것도 바꾸지 않는다. 메일·메시지 본문, 클립보드,
// 파일 내용은 읽지 않는다. 한국어 한 줄씩 모아 "ctx <base64>" 로 돌려준다(Godot 가 Claude 프롬프트에 붙인다).
// 권한: 캘린더·미리 알림·위치(처음 한 번 묻는다), 음악·Spotify·메일(실행 중일 때만, 자동화 권한).
// 권한 문구(Info.plist)가 없는 실행(개발 중 res://helper/bubble)에서는 묻지 않는다. 물으면 죽는다.

func hasUsage(_ key: String) -> Bool { Bundle.main.object(forInfoDictionaryKey: key) != nil }

// 다른 앱에 AppleScript 로 묻는다(백그라운드에서만 부를 것). 처음엔 자동화 권한 창이 떠서 오래 걸릴 수 있다.
func osa(_ src: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", src]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let deadline = Date().addingTimeInterval(90)
    while p.isRunning && Date() < deadline { usleep(50_000) }
    if p.isRunning { p.terminate(); return "" }
    let d = out.fileHandleForReading.readDataToEndOfFile()
    return (String(data: d, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

func hm(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
}

func cut(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n)) + "…" }

// WMO 날씨 코드 → 한국어
func sky(_ c: Int) -> String {
    switch c {
    case 0: return "맑음"
    case 1: return "대체로 맑음"
    case 2: return "구름 조금"
    case 3: return "흐림"
    case 45, 48: return "안개"
    case 51...57: return "이슬비"
    case 66, 67: return "어는 비"
    case 61...65: return "비"
    case 71...77: return "눈"
    case 80...82: return "소나기"
    case 85, 86: return "눈 소나기"
    case 95...99: return "뇌우"
    default: return "알 수 없음"
    }
}

final class MacContext: NSObject, CLLocationManagerDelegate {
    let store = EKEventStore()
    let loc = CLLocationManager()
    var place: (lat: Double, lon: Double, name: String, t: Date)?
    var locating = false
    var locDone: [() -> Void] = []
    var weather: (lines: [String], t: Date)?
    var lastApp: NSRunningApplication?   // 이 앱을 빼고 마지막으로 앞에 있던 앱
    var busy = false

    override init() {
        super.init()
        loc.delegate = self
        if let a = NSWorkspace.shared.frontmostApplication, !own(a) { lastApp = a }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  !self.own(a) else { return }
            self.lastApp = a
        }
    }

    func own(_ a: NSRunningApplication) -> Bool {
        a.processIdentifier == getpid() || a.processIdentifier == getppid()
    }

    // 모두 모아 한 번에 보낸다. 느린 것(날씨·할 일·AppleScript)은 기다렸다가.
    func gather() {
        if busy { return }
        busy = true
        var lines: [String] = []
        var slow: [String: [String]] = [:]
        let lock = NSLock()
        let g = DispatchGroup()
        func put(_ k: String, _ v: [String]) { lock.lock(); slow[k] = v; lock.unlock() }

        lines += system()
        g.enter()
        access(.event) { ok in
            put("cal", ok ? self.events() : [])
            g.leave()
        }
        g.enter()
        access(.reminder) { ok in
            if !ok { g.leave(); return }
            self.reminders { put("rem", $0); g.leave() }
        }
        g.enter()
        locate {
            self.fetchWeather { put("wx", $0); g.leave() }
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        g.enter()
        DispatchQueue.global().async {
            put("osa", self.scripted(running))
            g.leave()
        }
        g.notify(queue: .main) {
            for k in ["cal", "rem", "wx", "osa"] { lines += slow[k] ?? [] }
            let text = lines.joined(separator: "\n")
            emit("ctx " + Data(text.utf8).base64EncodedString())
            self.busy = false
        }
    }

    // ------------------------------------------------ 권한 없이 바로 아는 것
    func system() -> [String] {
        var out: [String] = []
        let name = NSFullUserName()
        if !name.isEmpty { out.append("맥 사용자 이름: \(name)") }
        if let a = lastApp, !a.isTerminated, let n = a.localizedName {
            var s = "지금 쓰는 앱: \(n)"
            if let title = windowTitle(a.processIdentifier), !title.isEmpty, title != n {
                s += " (창 제목: \(cut(title, 70)))"
            }
            out.append(s)
        }
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !own($0) && $0.bundleIdentifier != "com.apple.finder" }
            .compactMap { $0.localizedName }
        if !apps.isEmpty { out.append("켜 둔 앱: " + apps.prefix(30).joined(separator: ", ")) }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                           eventType: CGEventType(rawValue: ~0)!)
        if idle >= 120 { out.append("사용자가 키보드·마우스를 안 만진 지 \(Int(idle / 60))분") }
        out += battery()
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = v.volumeAvailableCapacityForImportantUsage {
            out.append("디스크 남은 공간: \(free / 1_000_000_000)GB")
        }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        out.append("화면 모드: \(dark ? "다크" : "라이트")")
        return out
    }

    // 그 앱의 맨 앞 창 제목(화면 기록 권한이 있어야 보인다).
    func windowTitle(_ pid: pid_t) -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            if let t = w[kCGWindowName as String] as? String, !t.isEmpty { return t }
        }
        return nil
    }

    func battery() -> [String] {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let pct = cur * 100 / max
            let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            let ac = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return ["배터리: \(pct)%" + (charging ? ", 충전 중" : ac ? ", 전원 연결됨" : ", 배터리로 쓰는 중")]
        }
        return []
    }

    // ------------------------------------------------ 캘린더·미리 알림
    func access(_ type: EKEntityType, _ done: @escaping (Bool) -> Void) {
        let key = type == .event ? "NSCalendarsFullAccessUsageDescription" : "NSRemindersFullAccessUsageDescription"
        let st = EKEventStore.authorizationStatus(for: type)
        if st.rawValue == 3 { done(true); return }          // fullAccess(=예전 authorized)
        guard st == .notDetermined, hasUsage(key) else { done(false); return }
        let cb: (Bool, Error?) -> Void = { ok, _ in DispatchQueue.main.async { done(ok) } }
        if #available(macOS 14, *) {
            if type == .event { store.requestFullAccessToEvents(completion: cb) }
            else { store.requestFullAccessToReminders(completion: cb) }
        } else {
            store.requestAccess(to: type, completion: cb)
        }
    }

    // 오늘·내일 일정(지난 것은 뺀다). 하루 종일 일정(공휴일·생일 포함)도.
    func events() -> [String] {
        let cal = Calendar.current, now = Date()
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 2, to: start)!
        let evs = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { $0.endDate > now }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
        var out: [String] = []
        for e in evs.prefix(8) {
            let title = cut(e.title ?? "(제목 없음)", 40)
            let day = cal.isDateInToday(e.startDate) || e.startDate < now ? "오늘" : "내일"
            if e.isAllDay {
                out.append("일정: \(day) 하루 종일 \(title)")
            } else if e.startDate <= now {
                out.append("일정: 지금 진행 중 \(title) (\(hm(e.endDate))까지)")
            } else {
                let mins = Int(e.startDate.timeIntervalSince(now) / 60)
                let left = mins < 60 ? "\(mins)분 뒤" : mins < 24 * 60 ? "\(mins / 60)시간 뒤" : ""
                out.append("일정: \(day) \(hm(e.startDate)) \(title)" + (left.isEmpty ? "" : " (\(left))"))
            }
        }
        if out.isEmpty { out.append("일정: 오늘·내일 남은 일정 없음") }
        return out
    }

    // 끝내지 않은 할 일. 기한이 있는 것(지난 것, 가까운 것)부터.
    func reminders(_ done: @escaping ([String]) -> Void) {
        let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: pred) { rs in
            let cal = Calendar.current, now = Date()
            func due(_ r: EKReminder) -> Date? { r.dueDateComponents.flatMap { cal.date(from: $0) } }
            let sorted = (rs ?? []).sorted {
                switch (due($0), due($1)) {
                case let (a?, b?): return a < b
                case (_?, nil): return true
                default: return false
                }
            }
            var out: [String] = []
            for r in sorted.prefix(6) {
                var s = "할 일: \(cut(r.title ?? "", 40))"
                if let d = due(r) {
                    let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 0
                    s += days < 0 ? " (\(-days)일 지남)" : days == 0 ? " (오늘까지)" : days == 1 ? " (내일까지)" : " (\(days)일 뒤까지)"
                }
                out.append(s)
            }
            DispatchQueue.main.async { done(out) }
        }
    }

    // ------------------------------------------------ 위치·날씨
    // 맥 위치 서비스를 먼저 쓰고, 안 되면(거절·실패·15초) 인터넷 주소로 대략의 도시를 잡는다. 한 시간 둔다.
    func locate(_ done: @escaping () -> Void) {
        if let p = place, Date().timeIntervalSince(p.t) < 3600 { done(); return }
        locDone.append(done)
        if locating { return }
        locating = true
        let st = loc.authorizationStatus
        if st == .denied || st == .restricted || !hasUsage("NSLocationUsageDescription") { ipLocate(); return }
        if st == .notDetermined { loc.requestWhenInUseAuthorization() } else { loc.requestLocation() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            if self?.locating == true { self?.ipLocate() }
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        guard locating else { return }
        switch m.authorizationStatus {
        case .notDetermined: break
        case .denied, .restricted: ipLocate()
        default: m.requestLocation()
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations ls: [CLLocation]) {
        guard locating, let l = ls.last else { return }
        CLGeocoder().reverseGeocodeLocation(l, preferredLocale: Locale(identifier: "ko_KR")) { ps, _ in
            let p = ps?.first
            let name = [p?.locality, p?.subLocality].compactMap { $0 }.joined(separator: " ")
            DispatchQueue.main.async { self.found(l.coordinate.latitude, l.coordinate.longitude, name) }
        }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        if locating { ipLocate() }
    }

    func ipLocate() {
        guard let url = URL(string: "https://get.geojs.io/v1/ip/geo.json") else { return }
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 10)) { d, _, _ in
            let j = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let lat = Double(j?["latitude"] as? String ?? ""), lon = Double(j?["longitude"] as? String ?? "")
            DispatchQueue.main.async {
                guard let lat, let lon else { self.found(nil, nil, ""); return }
                // 이름은 한국어로(위치 권한 없이도 된다). 안 되면 영어 도시 이름.
                CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon),
                                                    preferredLocale: Locale(identifier: "ko_KR")) { ps, _ in
                    let p = ps?.first
                    let name = [p?.locality, p?.subLocality].compactMap { $0 }.joined(separator: " ")
                    DispatchQueue.main.async { self.found(lat, lon, name.isEmpty ? (j?["city"] as? String ?? "") : name) }
                }
            }
        }.resume()
    }

    func found(_ lat: Double?, _ lon: Double?, _ name: String) {
        guard locating else { return }
        locating = false
        if let lat, let lon {
            if let old = place, abs(old.lat - lat) + abs(old.lon - lon) > 0.05 { weather = nil }
            place = (lat, lon, name, Date())
        }
        let cbs = locDone
        locDone = []
        cbs.forEach { $0() }
    }

    // Open-Meteo(가입·키 없음). 30분 둔다.
    func fetchWeather(_ done: @escaping ([String]) -> Void) {
        guard let p = place else { done([]); return }
        if let w = weather, Date().timeIntervalSince(w.t) < 1800 { done(w.lines); return }
        let q = "latitude=\(p.lat)&longitude=\(p.lon)&timezone=auto"
        let wx = "https://api.open-meteo.com/v1/forecast?\(q)&forecast_days=2&wind_speed_unit=ms"
            + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m"
            + "&hourly=precipitation_probability,weather_code"
            + "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset,uv_index_max"
        let air = "https://air-quality-api.open-meteo.com/v1/air-quality?\(q)&current=pm10,pm2_5"
        // Open-Meteo 날씨 서버가 막히는 때가 있어서(2026-11-14 집 네트워크에서 연결 안 됨) 안 되면 노르웨이 기상청(met.no).
        let met = "https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=\(String(format: "%.3f", p.lat))&lon=\(String(format: "%.3f", p.lon))"
        var js: [Int: [String: Any]] = [:]
        let g = DispatchGroup()
        for (i, u) in [wx, air, met].enumerated() {
            guard let url = URL(string: u) else { continue }
            var r = URLRequest(url: url, timeoutInterval: 10)
            r.setValue("37RHHG/1.0 (desktop character app)", forHTTPHeaderField: "User-Agent")   // met.no 는 이게 없으면 거절
            g.enter()
            URLSession.shared.dataTask(with: r) { d, _, _ in
                let j = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                DispatchQueue.main.async { if let j { js[i] = j }; g.leave() }
            }.resume()
        }
        g.notify(queue: .main) {
            var lines = self.weatherLines(p.name, js[0], js[1])
            if lines.isEmpty { lines = self.metLines(p.name, js[2], js[1]) }
            if !lines.isEmpty { self.weather = (lines, Date()) }
            done(lines)
        }
    }

    func dust(_ a: [String: Any]?) -> [String] {
        guard let c = a?["current"] as? [String: Any], let p10 = c["pm10"] as? Double, let p25 = c["pm2_5"] as? Double else { return [] }
        let pm10 = Int(p10.rounded()), pm25 = Int(p25.rounded())
        func grade(_ v: Int, _ t: [Int]) -> String { v <= t[0] ? "좋음" : v <= t[1] ? "보통" : v <= t[2] ? "나쁨" : "매우 나쁨" }
        return ["미세먼지 \(pm10)㎍/㎥(\(grade(pm10, [30, 80, 150]))), 초미세먼지 \(pm25)㎍/㎥(\(grade(pm25, [15, 35, 75])))"]
    }

    // met.no 기호 이름 → 한국어
    func metSky(_ code: String) -> String {
        let c = code.components(separatedBy: "_").first ?? code
        if c.contains("thunder") { return "뇌우" }
        if c.contains("sleet") { return "진눈깨비" }
        if c.contains("snow") { return c.contains("showers") ? "눈 소나기" : "눈" }
        if c.contains("rain") {
            if c.contains("showers") { return "소나기" }
            return c.hasPrefix("light") ? "약한 비" : c.hasPrefix("heavy") ? "강한 비" : "비"
        }
        switch c {
        case "clearsky": return "맑음"
        case "fair": return "대체로 맑음"
        case "partlycloudy": return "구름 조금"
        case "cloudy": return "흐림"
        case "fog": return "안개"
        default: return c
        }
    }

    func metLines(_ name: String, _ w: [String: Any]?, _ a: [String: Any]?) -> [String] {
        guard let props = w?["properties"] as? [String: Any], let ts = props["timeseries"] as? [[String: Any]], !ts.isEmpty
        else { return [] }
        let iso = ISO8601DateFormatter()
        let cal = Calendar.current, now = Date()
        typealias Row = (t: Date, temp: Double, rh: Double, wind: Double, sym: String, rain: Double)
        var rows: [Row] = []
        for e in ts {
            guard let t = (e["time"] as? String).flatMap({ iso.date(from: $0) }),
                  let data = e["data"] as? [String: Any],
                  let det = ((data["instant"] as? [String: Any])?["details"]) as? [String: Any] else { continue }
            let next = (data["next_1_hours"] ?? data["next_6_hours"]) as? [String: Any]
            let sym = ((next?["summary"] as? [String: Any])?["symbol_code"] as? String) ?? ""
            let rain = ((next?["details"] as? [String: Any])?["precipitation_amount"] as? Double) ?? 0
            rows.append((t, det["air_temperature"] as? Double ?? 0, det["relative_humidity"] as? Double ?? 0,
                         det["wind_speed"] as? Double ?? 0, sym, rain))
        }
        guard let cur = rows.first(where: { $0.t.addingTimeInterval(3600) > now }) else { return [] }
        var out: [String] = []
        let at = name.isEmpty ? "" : "(\(name))"
        out.append("날씨\(at): 지금 \(metSky(cur.sym)) \(Int(cur.temp.rounded()))℃, 습도 \(Int(cur.rh.rounded()))%, 바람 \(Int(cur.wind.rounded()))m/s")
        for (off, label) in [(0, "오늘 남은 시간"), (1, "내일")] {
            guard let day = cal.date(byAdding: .day, value: off, to: now) else { continue }
            let rs = rows.filter { cal.isDate($0.t, inSameDayAs: day) && $0.t >= cur.t }
            guard let lo = rs.map(\.temp).min(), let hi = rs.map(\.temp).max() else { continue }
            let wet = rs.filter { $0.rain >= 0.2 }
            let mid = rs.min { abs($0.t.timeIntervalSince(day) ) < abs($1.t.timeIntervalSince(day)) }
            let sky = wet.isEmpty ? metSky((off == 1 ? rs.first { cal.component(.hour, from: $0.t) >= 12 } ?? mid : mid)?.sym ?? "") : metSky(wet[0].sym)
            out.append("\(label): \(sky), \(Int(lo.rounded()))~\(Int(hi.rounded()))℃" + (wet.isEmpty ? ", 비·눈 없음" : ", 비·눈 있음"))
        }
        let soon = rows.filter { $0.t >= cur.t && $0.t < now.addingTimeInterval(12 * 3600) }
        if let r = soon.first(where: { $0.rain >= 0.2 }) {
            out.append("앞으로 12시간: \(cal.component(.hour, from: r.t))시쯤 \(metSky(r.sym))(시간당 \(r.rain)mm)")
        } else {
            out.append("앞으로 12시간: 비·눈 소식 없음")
        }
        return out + dust(a)
    }

    func weatherLines(_ name: String, _ w: [String: Any]?, _ a: [String: Any]?) -> [String] {
        guard let w, let cur = w["current"] as? [String: Any] else { return [] }
        func n(_ v: Any?) -> Int { Int(((v as? Double) ?? Double((v as? Int) ?? 0)).rounded()) }
        var out: [String] = []
        let at = name.isEmpty ? "" : "(\(name))"
        out.append("날씨\(at): 지금 \(sky(n(cur["weather_code"]))) \(n(cur["temperature_2m"]))℃(체감 \(n(cur["apparent_temperature"]))℃), "
                   + "습도 \(n(cur["relative_humidity_2m"]))%, 바람 \(n(cur["wind_speed_10m"]))m/s")
        if let d = w["daily"] as? [String: Any] {
            func col(_ k: String) -> [Any] { d[k] as? [Any] ?? [] }
            func hhmm(_ v: Any?) -> String { (v as? String)?.components(separatedBy: "T").last ?? "" }
            for (i, label) in [(0, "오늘"), (1, "내일")] where col("weather_code").count > i {
                var s = "\(label): \(sky(n(col("weather_code")[i]))), \(n(col("temperature_2m_min")[i]))~\(n(col("temperature_2m_max")[i]))℃, "
                    + "비·눈 확률 최대 \(n(col("precipitation_probability_max")[i]))%"
                if i == 0 {
                    s += ", 해 뜸 \(hhmm(col("sunrise").first)) 해 짐 \(hhmm(col("sunset").first)), 자외선 지수 \(n(col("uv_index_max").first))"
                }
                out.append(s)
            }
        }
        // 앞으로 12시간 안에 비·눈이 올 것 같은 첫 시각
        if let h = w["hourly"] as? [String: Any], let times = h["time"] as? [String],
           let probs = h["precipitation_probability"] as? [Any], let codes = h["weather_code"] as? [Any],
           let now = cur["time"] as? String,
           let i0 = times.firstIndex(where: { $0.prefix(13) == now.prefix(13) }) {
            var said = false
            for i in i0..<min(i0 + 12, times.count, probs.count, codes.count) where n(probs[i]) >= 50 {
                let hour = times[i].components(separatedBy: "T").last?.prefix(2) ?? ""
                out.append("앞으로 12시간: \(hour)시쯤 \(sky(n(codes[i]))) 가능성(확률 \(n(probs[i]))%)")
                said = true
                break
            }
            if !said { out.append("앞으로 12시간: 비·눈 소식 없음") }
        }
        return out + dust(a)
    }

    // ------------------------------------------------ 다른 앱(실행 중일 때만 묻는다. 안 켜져 있으면 깨우지 않는다)
    func scripted(_ running: Set<String>) -> [String] {
        var out: [String] = []
        if running.contains("com.apple.Music") {
            let s = osa("tell application \"Music\" to if player state is playing then return (name of current track) & \" — \" & (artist of current track)")
            if !s.isEmpty { out.append("음악 앱에서 듣는 중: \(cut(s, 60))") }
        }
        if running.contains("com.spotify.client") {
            let s = osa("tell application \"Spotify\" to if player state is playing then return (name of current track) & \" — \" & (artist of current track)")
            if !s.isEmpty { out.append("Spotify 에서 듣는 중: \(cut(s, 60))") }
        }
        out += browsers(running)
        if running.contains("com.apple.mail") {
            let s = osa("tell application \"Mail\" to return unread count of inbox")
            if let c = Int(s) { out.append("메일 받은 편지함의 읽지 않은 메일: \(c)통") }
        }
        return out
    }
}

extension MacContext {
    // 켜져 있는 브라우저마다 보고 있는 탭(제목·사이트)과 열린 유튜브 영상. 재생 중인지는 모른다
    // (알려면 브라우저에서 "Apple 이벤트의 JavaScript 허용"을 켜야 해서 안 한다).
    func browsers(_ running: Set<String>) -> [String] {
        // (번들 id, 앱 이름, 탭 제목 속성, 지금 탭 속성)
        let list = [("company.thebrowser.Browser", "Arc", "title", "active tab"),
                    ("company.thebrowser.dia", "Dia", "title", "active tab"),
                    ("com.google.Chrome", "Google Chrome", "title", "active tab"),
                    ("com.brave.Browser", "Brave Browser", "title", "active tab"),
                    ("com.microsoft.edgemac", "Microsoft Edge", "title", "active tab"),
                    ("com.naver.Whale", "Whale", "title", "active tab"),
                    ("com.apple.Safari", "Safari", "name", "current tab")]
        var out: [String] = []
        for (id, app, title, cur) in list where running.contains(id) {
            let s = osa("""
            tell application "\(app)"
                set out to ""
                try
                    -- 창 이름이 지금 탭 제목이다(Arc 는 탭의 title 이 "YouTube" 처럼 낡아 있을 때가 있다).
                    set nm to name of front window
                    set u to ""
                    try
                        set u to URL of (\(cur) of front window)
                    end try
                    set out to "A|" & nm & "|" & u & linefeed
                end try
                set n to 0
                repeat with w in windows
                    try
                        repeat with t in tabs of w
                            set u to URL of t
                            if n < 3 and (u contains "youtube.com/watch" or u contains "youtu.be/") then
                                set out to out & "Y|" & (\(title) of t) & "|" & u & linefeed
                                set n to n + 1
                            end if
                        end repeat
                    end try
                end repeat
                return out
            end tell
            """)
            let short = app == "Google Chrome" ? "Chrome" : app
            for line in s.split(separator: "\n") {
                let f = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard f.count == 3, !f[1].isEmpty else { continue }
                if f[0] == "A" {
                    let host = URL(string: f[2])?.host?.replacingOccurrences(of: "www.", with: "") ?? ""
                    out.append("\(short) 에서 보는 탭: \(cut(f[1], 60))" + (host.isEmpty ? "" : " (\(host))"))
                } else if f[1] != "YouTube" {   // 아직 안 불러온 탭은 제목이 그냥 YouTube
                    out.append("\(short) 에 열린 유튜브: \(cut(f[1].replacingOccurrences(of: " - YouTube", with: ""), 60))")
                }
            }
        }
        return out
    }
}

// ---------------------------------------------------------------- 다른 앱 움직이기
// 사용자가 부탁했을 때만(Claude 가 도구를 고르면 Godot 이 보낸다). 되돌리기 어려운 것(보내기·지우기)은 없다.
// 할 일·일정 넣기는 Godot 이 먼저 사용자에게 물어보고 나서 보낸다. 결과: "acted <id> ok|fail <base64 한마디>"

func osaQuote(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

func localDate(_ s: String) -> Date? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    for fmt in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
        f.dateFormat = fmt
        if let d = f.date(from: s) { return d }
    }
    return nil
}

extension MacContext {
    func act(id: Int, name: String, input: [String: Any]) {
        let done: (Bool, String) -> Void = { ok, msg in
            DispatchQueue.main.async { emit("acted \(id) \(ok ? "ok" : "fail") " + Data(msg.utf8).base64EncodedString()) }
        }
        func str(_ k: String) -> String { (input[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        switch name {
        case "music":
            DispatchQueue.global().async { self.music(str("action"), str("query"), str("app"), done) }
        case "volume":
            let lv = max(0, min(100, (input["level"] as? Int) ?? Int((input["level"] as? Double) ?? 50)))
            DispatchQueue.global().async {
                _ = osa("set volume output volume \(lv)")
                done(true, "소리 크기를 \(lv)로 맞췄어.")
            }
        case "open_app":
            let app = str("name")
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["-a", app]
                p.standardError = FileHandle.nullDevice
                p.standardOutput = FileHandle.nullDevice
                do { try p.run(); p.waitUntilExit() } catch {}
                let ok = p.terminationStatus == 0
                done(ok, ok ? "\(app) 열었어." : "\(app) 앱을 못 찾았어.")
            }
        case "open_url":
            guard let u = URL(string: str("url")), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else {
                done(false, "그 주소는 못 열겠어."); return
            }
            NSWorkspace.shared.open(u)
            done(true, "열었어.")
        case "add_reminder":
            guard EKEventStore.authorizationStatus(for: .reminder).rawValue == 3,
                  let cal = store.defaultCalendarForNewReminders() else { done(false, "미리 알림 권한이 없어."); return }
            let r = EKReminder(eventStore: store)
            r.title = str("title")
            r.calendar = cal
            if let d = localDate(str("due")) {
                r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
                if str("due").count > 10 { r.addAlarm(EKAlarm(absoluteDate: d)) }
            }
            do { try store.save(r, commit: true); done(true, "할 일에 넣었어.") }
            catch { done(false, "할 일에 못 넣었어.") }
        case "add_event":
            guard EKEventStore.authorizationStatus(for: .event).rawValue == 3,
                  let cal = store.defaultCalendarForNewEvents else { done(false, "캘린더 권한이 없어."); return }
            guard let start = localDate(str("start")) else { done(false, "시간을 잘 모르겠어."); return }
            let mins = (input["minutes"] as? Int) ?? Int((input["minutes"] as? Double) ?? 60)
            let e = EKEvent(eventStore: store)
            e.title = str("title")
            e.calendar = cal
            e.startDate = start
            e.endDate = start.addingTimeInterval(Double(max(5, mins)) * 60)
            do { try store.save(e, span: .thisEvent, commit: true); done(true, "캘린더에 넣었어.") }
            catch { done(false, "캘린더에 못 넣었어.") }
        default:
            done(false, "그건 아직 못 해.")
        }
    }

    // 음악 앱 또는 Spotify. app 을 안 정하면 켜져 있는 쪽(둘 다 아니면 음악 앱).
    func music(_ action: String, _ query: String, _ app0: String, _ done: (Bool, String) -> Void) {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        var app = app0
        if app != "Music" && app != "Spotify" {
            app = running.contains("com.spotify.client") && !running.contains("com.apple.Music") ? "Spotify" : "Music"
        }
        let tell = "tell application \"\(app)\" to "
        switch action {
        case "pause": _ = osa(tell + "pause"); done(true, "멈췄어.")
        case "next": _ = osa(tell + "next track"); done(true, "다음 곡!")
        case "previous": _ = osa(tell + "previous track"); done(true, "이전 곡!")
        case "search_play" where !query.isEmpty:
            if app == "Spotify" { done(false, "Spotify 는 찾아서 틀 수가 없어. 음악 앱이면 돼."); return }
            let q = osaQuote(query)
            let s = osa("""
            tell application "Music"
                if exists user playlist \(q) then
                    play user playlist \(q)
                    return "목록 " & \(q)
                end if
                set r to (search library playlist 1 for \(q))
                if r is {} then return ""
                play item 1 of r
                return (name of item 1 of r) & " — " & (artist of item 1 of r)
            end tell
            """)
            done(!s.isEmpty, s.isEmpty ? "보관함에서 '\(query)'을 못 찾았어." : "\(s) 틀었어.")
        default:
            _ = osa(tell + "play")
            let s = osa(tell + "if player state is playing then return (name of current track) & \" — \" & (artist of current track)")
            done(true, s.isEmpty ? "틀었어." : "\(s) 틀었어.")
        }
    }
}

// Godot 는 이 도우미의 표준 오류 파이프를 읽지 않고 닫는다. 그 상태에서 AppKit 이 표준 오류에
// 무언가 쓰면(입력칸에 포커스가 갈 때 입력기 로그 등) SIGPIPE 로 조용히 죽는다.
// 그래서 SIGPIPE 를 무시하고 표준 오류는 버린다.
signal(SIGPIPE, SIG_IGN)
freopen("/dev/null", "w", stderr)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let talk = Talk()
let macContext = MacContext()
let prints = Prints()
let voice = Voice()
Thread.detachNewThread {
    while let line = readLine() {
        guard let d = line.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
        DispatchQueue.main.async { talk.handle(j) }
    }
    exit(0)
}
app.run()
