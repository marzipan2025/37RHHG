// 말 도우미. 캐릭터의 말은 상자 없이 머리 위에 글씨로만 띄우고, 답장 입력칸은 발치에 띄운다.
// Godot 창 밖에 그려야 하고(창은 캐릭터 크기뿐), 입력칸은 메뉴와 같은 유리 재질
// (macOS 26+ NSGlassEffectView, 그 전 OS 는 NSVisualEffectView)을 쓰려고 네이티브로 따로 뺐다.
//
// 표준 입력(한 줄에 JSON 하나). 좌표는 화면 pt, 왼쪽 위 원점.
//   {"op":"say","text":"…", "x":..,"y":..,"fy":..}   머리끝 가운데 (x,y), 발 높이 fy
//   {"op":"input","mode":"reply|key", …}            발치에 입력칸
//   {"op":"move","x":..,"y":..,"fy":..}
//   {"op":"hidetext"} {"op":"hideinput"} {"op":"hide"}
// 표준 출력(한 줄씩): "click"(글씨를 누름) | "esc"(Esc 또는 5초간 입력 없음) | "submit <base64 글>"
// 표준 입력이 닫히면(앱이 끝나면) 같이 끝난다.
import Cocoa

let textMaxW: CGFloat = 320    // 글 최대 폭
let fontSize: CGFloat = 22
let fontName = "BusanDandiScript"   // 부산단디체(손글씨). 없으면 시스템 글꼴.
let inputW: CGFloat = 240
let inputIdle: TimeInterval = 5.0   // 입력이 이만큼 없으면 입력칸을 닫는다(답장일 때만)

func emit(_ s: String) {
    FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
}

// 상자가 없어서 어떤 바탕에서도 읽히도록 테두리를 먼저 그리고 그 위에 글씨를 그린다.
final class TextView: NSView {
    var text = ""
    var font = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize, weight: .medium)
    static let margin: CGFloat = 6

    func attrs(stroke: Bool) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineBreakMode = .byWordWrapping
        // 라이트 모드: 검은 글씨에 흰 테두리. 다크 모드: 흰 글씨에 검은 테두리. 테두리는 반투명.
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var a: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: p,
                                                .foregroundColor: dark ? NSColor.white : NSColor.black]
        if stroke {
            a[.strokeColor] = (dark ? NSColor.black : NSColor.white).withAlphaComponent(0.5)
            a[.strokeWidth] = 12.0          // 글자 크기의 %, 양수면 테두리만 그린다
        }
        return a
    }

    func fit() -> NSSize {
        let r = (text as NSString).boundingRect(with: NSSize(width: textMaxW, height: 4000),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs(stroke: false))
        return NSSize(width: ceil(r.width) + TextView.margin * 2, height: ceil(r.height) + TextView.margin * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: TextView.margin, dy: TextView.margin)
        let s = text as NSString
        s.draw(with: r, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs(stroke: true))
        s.draw(with: r, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs(stroke: false))
    }
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
    let inputPanel = makePanel(InputPanel.self, shadow: true)
    let inputBox = NSView()
    var field: NSTextField = NSTextField()
    var head = CGPoint.zero
    var feetY: CGFloat = 0
    var idle: Timer?
    var idleOn = false

    override init() {
        super.init()
        textPanel.contentView = textView
        let radius: CGFloat = 14
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.contentView = inputBox
            inputPanel.contentView = glass
        } else {
            let fx = NSVisualEffectView()
            fx.material = .menu
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = radius
            fx.layer?.masksToBounds = true
            inputBox.autoresizingMask = [.width, .height]
            fx.addSubview(inputBox)
            inputPanel.contentView = fx
        }
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
            var o = NSPoint(x: a.x - s.width / 2, y: a.y + 2)
            o.y = min(o.y, vis.maxY - s.height)
            o.x = max(vis.minX, min(o.x, vis.maxX - s.width))
            textPanel.setFrameOrigin(o)
        }
        if inputPanel.isVisible {
            // 발치 가운데. 화면 아래로 나가면 화면 안에 걸친다.
            let s = inputPanel.frame.size
            let f = cocoa(CGPoint(x: head.x, y: feetY))
            var o = NSPoint(x: f.x - s.width / 2, y: f.y - 6 - s.height)
            o.y = max(o.y, vis.minY + 4)
            o.x = max(vis.minX, min(o.x, vis.maxX - s.width))
            inputPanel.setFrameOrigin(o)
        }
    }

    func say(_ text: String) {
        textView.text = text
        let s = textView.fit()
        textPanel.setContentSize(s)
        textView.frame = NSRect(origin: .zero, size: s)
        textView.needsDisplay = true
        textPanel.orderFrontRegardless()
        place()
        // 확인용: BUBBLE_DUMP=경로 를 주면 글씨 그림을 회색 바탕 PNG 로 남긴다.
        if let path = ProcessInfo.processInfo.environment["BUBBLE_DUMP"],
           let rep = textView.bitmapImageRepForCachingDisplay(in: textView.bounds) {
            textView.cacheDisplay(in: textView.bounds, to: rep)
            let img = NSImage(size: textView.bounds.size)
            img.lockFocus()
            NSColor(white: 0.45, alpha: 1).setFill()
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
        field.placeholderString = mode == "key" ? "키를 붙여 넣고 Enter" : "답장 쓰고 Enter"
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        let size = NSSize(width: inputW, height: 36)
        inputPanel.setContentSize(size)
        inputBox.frame = NSRect(origin: .zero, size: size)
        field.frame = NSRect(x: 12, y: 8, width: size.width - 24, height: 20)
        inputBox.addSubview(field)
        inputPanel.makeKeyAndOrderFront(nil)
        inputPanel.makeFirstResponder(field)
        place()
        idleOn = mode != "key"
        touch()
    }

    // 입력이 있을 때마다 5초 타이머를 다시 건다.
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
        inputPanel.orderOut(nil)
    }

    @objc func submit() {
        let d = field.stringValue.data(using: .utf8) ?? Data()
        emit("submit " + d.base64EncodedString())
    }

    func controlTextDidChange(_ obj: Notification) { touch() }

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
