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
// 표준 출력(한 줄씩): "over"/"out"(마우스가 글씨 위에 들어옴/나감) | "click"(글씨를 누름) | "typing"(입력칸에 처음 글을 침)
//                   | "esc"(Esc, 또는 아무것도 안 친 채 5초) | "submit <base64 글>"
//                   | "menu <버튼 이름>"(메뉴 버튼을 누름) | "menuclose"(바깥을 눌렀거나 한동안 안 써서 닫힘)
//                   | "grid <열> <행> <화면 x> <화면 y> <칸 pt> <base64 busy> <base64 edge>" | "noscan"(권한 없음·실패)
// 표준 입력이 닫히면(앱이 끝나면) 같이 끝난다.
import Cocoa
import ScreenCaptureKit

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
        case "scan": scan(at: CGPoint(x: j["px"] as? Double ?? 0, y: j["py"] as? Double ?? 0), cell: CGFloat(j["cell"] as? Double ?? 16))
        default: break
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
Thread.detachNewThread {
    while let line = readLine() {
        guard let d = line.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
        DispatchQueue.main.async { talk.handle(j) }
    }
    exit(0)
}
app.run()
