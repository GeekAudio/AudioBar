import Cocoa
import CoreAudio
import ServiceManagement
import IOKit

// MARK: - CoreAudio 辅助

struct AudioDev {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let index: Int        // UID 里的引擎序号
    let isInput: Bool
}

func propString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var cf: CFString? = nil
    let st = withUnsafeMutablePointer(to: &cf) { p -> OSStatus in
        AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, p)
    }
    return (st == noErr && cf != nil) ? (cf! as String) : ""
}

func channels(_ dev: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var s: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &s) == noErr, s > 0 else { return 0 }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(s), alignment: 16)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &s, buf) == noErr else { return 0 }
    var total = 0
    for b in UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self)) {
        total += Int(b.mNumberChannels)
    }
    return total
}

/// UID 形如 AppleHDAEngineInput:1F,3,0,1,0:3 —— 倒数第一个逗号后的数字是引擎序号
func engineIndex(from uid: String) -> Int {
    guard let colon = uid.firstIndex(of: ":") else { return -1 }
    let body = uid[uid.index(after: colon)...]
    let firstField = body.split(separator: ":").first.map(String.init) ?? ""
    let parts = firstField.split(separator: ",")
    guard let last = parts.last, let v = Int(last) else { return -1 }
    return v
}

func allAudioDevices() -> [AudioDev] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var devs = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devs)

    var result: [AudioDev] = []
    for d in devs {
        let uid = propString(d, kAudioDevicePropertyDeviceUID)
        let name = propString(d, kAudioObjectPropertyName)
        let idx = engineIndex(from: uid)
        if channels(d, kAudioObjectPropertyScopeOutput) > 0 {
            result.append(AudioDev(id: d, name: name, uid: uid, index: idx, isInput: false))
        }
        if channels(d, kAudioObjectPropertyScopeInput) > 0 {
            result.append(AudioDev(id: d, name: name, uid: uid, index: idx, isInput: true))
        }
    }
    return result
}

func defaultDevice(_ input: Bool) -> AudioDeviceID {
    let sel = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
    return dev
}

func setDefault(_ dev: AudioDeviceID, input: Bool) -> Bool {
    let sel = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var d = dev
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &d) == noErr
}

// MARK: - 音量 / 静音

func volumeAddress(_ dev: AudioDeviceID, input: Bool) -> AudioObjectPropertyAddress? {
    let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    for el in [kAudioObjectPropertyElementMain, 1] as [AudioObjectPropertyElement] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                           mScope: scope, mElement: el)
        if AudioObjectHasProperty(dev, &a) { return a }
    }
    return nil
}

func getVolume(_ dev: AudioDeviceID, input: Bool) -> Float? {
    guard var a = volumeAddress(dev, input: input) else { return nil }
    var v: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : nil
}

func setVolume(_ dev: AudioDeviceID, _ value: Float, input: Bool) {
    guard var a = volumeAddress(dev, input: input) else { return }
    var v = Float32(value)
    AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
}

func muteAddress(_ dev: AudioDeviceID, input: Bool) -> AudioObjectPropertyAddress? {
    let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    for el in [kAudioObjectPropertyElementMain, 1] as [AudioObjectPropertyElement] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                           mScope: scope, mElement: el)
        if AudioObjectHasProperty(dev, &a) { return a }
    }
    return nil
}

func getMute(_ dev: AudioDeviceID, input: Bool) -> Bool? {
    guard var a = muteAddress(dev, input: input) else { return nil }
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? (v != 0) : nil
}

func setMute(_ dev: AudioDeviceID, _ muted: Bool, input: Bool) {
    guard var a = muteAddress(dev, input: input) else { return }
    var v: UInt32 = muted ? 1 : 0
    AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
}

// MARK: - 面板丝印映射（按 codec 引擎序号）

/// 本机 ALC897：输入 0=0x18 后置粉、1=0x19 前置粉、2=0x1a 蓝；
/// 输出 3=0x14 后置绿、4=0x1b 前置耳机、5=0x1e 光纤
/// 返回：(中文名, 方向符号, 接口名, 颜色)
///
/// 用 → / ← 代替 OUT / IN 当方向标记，因为它们在系统字体里 **advance 完全相同（10.45pt）**：
/// 符号本身宽度一致 ⇒ 符号列对齐、后面的接口名起点也一致，
/// 于是「符号对齐 + 接口名对齐」两件事在**比例字体**下同时成立。
/// 直接写 "LINE OUT" / "MIC IN" 做不到——两个词的宽度差 24pt，怎么调 tab 都会歪。
func panelColumns(index: Int, isInput: Bool) -> (String, String, String, String)? {
    if isInput {
        switch index {
        case 0: return ("后置话筒", "←", "MIC", "粉")
        case 1: return ("前置话筒", "←", "MIC", "粉")
        case 2: return ("线路输入", "←", "LINE", "蓝")
        default: return nil
        }
    } else {
        switch index {
        case 3: return ("线路输出", "→", "LINE", "绿")
        case 4: return ("前置耳机", "→", "HP", "绿")
        case 5: return ("光纤输出", "→", "SPDIF", "光纤")
        default: return nil
        }
    }
}

// MARK: - codec 引脚配置（取颜色用，Hackintool 同款做法）

/// 从 IORegistry 的 AppleHDAController / HDAConfigDefault 读整份 pin config。
/// 一次属性读取即可，不用 alc-verb 逐节点发 verb。
/// 每个 UInt32 里：bit31=有插孔、bit20-23=device type、bit12-15=颜色
/// 返回 [(deviceType, 颜色名)]，顺序即节点 nid 升序
func codecPinColors() -> [(Int, String)] {
    var out: [(Int, String)] = []
    // 在控制器及其所有子节点里找 HDAConfigDefault（属性挂在 codec 子节点上）
    func scan(_ entry: io_registry_entry_t, depth: Int) {
        if out.isEmpty,
           let d = IORegistryEntryCreateCFProperty(entry, "HDAConfigDefault" as CFString,
                                                   kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data, d.count >= 4 {
            let words = d.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
            for v in words {
                guard (v & 0x8000_0000) != 0 else { continue }
                let color = colorName(Int((v >> 12) & 0xF))
                guard !color.isEmpty else { continue }
                out.append((Int((v >> 20) & 0xF), color))
            }
        }
        guard depth < 3 else { return }
        var child: io_iterator_t = 0
        if IORegistryEntryGetChildIterator(entry, kIOServicePlane, &child) == KERN_SUCCESS {
            var c = IOIteratorNext(child)
            while c != 0 {
                scan(c, depth: depth + 1)
                IOObjectRelease(c)
                c = IOIteratorNext(child)
            }
            IOObjectRelease(child)
        }
    }

    guard let match = IOServiceMatching("AppleHDAController") else { return out }
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS else { return out }
    var svc = IOIteratorNext(iter)
    while svc != 0 {
        scan(svc, depth: 0)
        IOObjectRelease(svc)
        svc = IOIteratorNext(iter)
    }
    IOObjectRelease(iter)
    return out
}

/// pin config 的颜色码 → 中文
func colorName(_ c: Int) -> String {
    switch c {
    case 1: return "黑"
    case 2: return "灰"
    case 3: return "蓝"
    case 4: return "绿"
    case 5: return "红"
    case 6: return "橙"
    case 7: return "黄"
    case 8: return "紫"
    case 9: return "粉"
    default: return ""
    }
}

/// 系统设备名 → HDA device type（用于和 codec 引脚配对）
func hdaDevType(_ name: String, isInput: Bool) -> Int? {
    let n = name.lowercased()
    if isInput {
        if n.contains("digital input") || n.contains("spdif") { return 4 }
        if n.contains("line input") || n.contains("linein")   { return 8 }
        if n.contains("microphone") || n.contains("mic")      { return 0xA }
        return nil
    } else {
        if n.contains("digital output") || n.contains("spdif") { return 4 }
        if n.contains("headphone")                             { return 2 }
        if n.contains("line output") || n.contains("lineout")  { return 0 }
        if n.contains("speaker")                               { return 1 }
        return nil
    }
}

/// 通用兜底：本机索引表没命中时，从 AppleHDA 给的系统设备名推导
/// 设备名本身携带类型（Built-in Line Output / Headphone / Microphone…），
/// 与 CoreAudio 枚举天然一一对应，不需要跨层映射 ⇒ 换任何机器都能显示
/// 缺点：拿不到插孔颜色，颜色列留空
func derivedColumns(name: String, isInput: Bool) -> (String, String, String, String)? {
    let n = name.lowercased()
    func has(_ k: String) -> Bool { n.contains(k) }

    let color = pinColor(for: name, isInput: isInput)

    if isInput {
        if has("digital input") || has("spdif") { return ("数字输入", "←", "SPDIF", color) }
        if has("line input") || has("linein")   { return ("线路输入", "←", "LINE",  "") }
        if has("microphone") || has("mic")      { return ("话筒",     "←", "MIC",   "") }
        return nil
    } else {
        if has("digital output") || has("spdif") { return ("光纤输出", "→", "SPDIF", color) }
        if has("headphone")                      { return ("耳机",     "→", "HP",    "") }
        if has("line output") || has("lineout")  { return ("线路输出", "→", "LINE",  "") }
        if has("speaker")                        { return ("扬声器",   "→", "SPK",   "") }
        return nil
    }
}

/// 给某个 CoreAudio 设备找它的插孔颜色。
/// 只做「同 device type 内按顺序配对」，并且**数量必须对得上**才采用——
/// 对不上就返回空，避免颜色张冠李戴（比没有更糟）。
func pinColor(for name: String, isInput: Bool) -> String {
    guard let dt = hdaDevType(name, isInput: isInput) else { return "" }
    let pins = codecPinColors().filter { $0.0 == dt }.map { $0.1 }
    guard !pins.isEmpty else { return "" }

    // 同一 device type 的 CoreAudio 设备（按显示顺序）
    let sameType = allAudioDevices()
        .filter { $0.isInput == isInput && hdaDevType($0.name, isInput: isInput) == dt }
        .sorted { sortRank(index: $0.index, isInput: isInput) < sortRank(index: $1.index, isInput: isInput) }
    guard sameType.count == pins.count,
          let idx = sameType.firstIndex(where: { $0.name == name }) else { return "" }
    return pins[idx]
}

/// 先查本机精确表，查不到再走通用推导
func columns(for d: AudioDev) -> (String, String, String, String)? {
    panelColumns(index: d.index, isInput: d.isInput) ?? derivedColumns(name: d.name, isInput: d.isInput)
}

func panelLabel(index: Int, isInput: Bool) -> String? {
    guard let c = panelColumns(index: index, isInput: isInput) else { return nil }
    return c.0
}

/// 菜单里的显示顺序：前置优先
func sortRank(index: Int, isInput: Bool) -> Int {
    if isInput {
        switch index {
        case 1: return 0        // 前置话筒
        case 0: return 1        // 后置话筒
        case 2: return 2        // 线路输入
        default: return 99
        }
    } else {
        switch index {
        case 4: return 0        // 前置耳机
        case 3: return 1        // 线路输出
        case 5: return 2        // 光纤输出
        default: return 99
        }
    }
}

// 三栏的 tab 停靠位（点）
//   66 = 方向符号（← / → 宽度恒定）
//   84 = 接口名（LINE / SPDIF / MIC）
//  128 = 颜色
// ★ defaultTabInterval 必须是 0：设成非 0 会生成额外的隐式停靠位，
//   把后面几列顶到画布外（实测宽度从 151 变成 264）
let kNameX: CGFloat  = 20      // 左边距 14+20=34
let kArrowX: CGFloat = 74
let kConnX: CGFloat  = 92
let kColorX: CGFloat = 151     // 颜色右对齐（行内坐标）：右侧留白 27

/// 颜色字用真实颜色渲染，不用读就知道是哪个口
func jackColor(_ c: String) -> NSColor {
    switch c {
    case "绿":   return NSColor(srgbRed: 0.13, green: 0.62, blue: 0.24, alpha: 1)
    case "粉":   return NSColor(srgbRed: 0.85, green: 0.28, blue: 0.55, alpha: 1)
    case "蓝":   return NSColor(srgbRed: 0.11, green: 0.44, blue: 0.85, alpha: 1)
    case "黑":   return NSColor(srgbRed: 0.25, green: 0.25, blue: 0.27, alpha: 1)
    case "灰":   return NSColor(srgbRed: 0.55, green: 0.55, blue: 0.57, alpha: 1)
    case "红":   return NSColor(srgbRed: 0.80, green: 0.25, blue: 0.25, alpha: 1)
    case "橙":   return NSColor(srgbRed: 0.85, green: 0.50, blue: 0.15, alpha: 1)
    case "黄":   return NSColor(srgbRed: 0.75, green: 0.65, blue: 0.15, alpha: 1)
    case "紫":   return NSColor(srgbRed: 0.55, green: 0.35, blue: 0.75, alpha: 1)
    default:    return NSColor.secondaryLabelColor
    }
}

/// 普通菜单项（声音设置/登录时启动/退出）也用同一套对齐：
/// 「圆点槽 + tab 到 kNameX」，这样它们和设备行的中文列严格对齐
func plainTitle(_ text: String, dot: Bool = false) -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.tabStops = [NSTextTab(textAlignment: .left, location: 18)]
    style.defaultTabInterval = 0

    let s = NSMutableAttributedString()
    s.append(NSAttributedString(string: dot ? "●" : " ", attributes: [
        .font: NSFont.systemFont(ofSize: 8),
        .foregroundColor: dot ? NSColor.controlAccentColor : NSColor.clear,
        .baselineOffset: 2,
        .paragraphStyle: style]))
    s.append(NSAttributedString(string: "\t" + text, attributes: [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: style]))
    return s
}

/// 中文 13pt 主色 / 方向符号 11.5pt 三级灰 / 接口名 11.5pt 次要灰 / 颜色字用插孔真实颜色
func alignedTitle(_ cn: String, _ arrow: String, _ conn: String, _ color: String,
                  dot: Bool = false) -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    // 四列：圆点 / 名字 / 方向符号 / 接口名 / 颜色
    style.tabStops = [NSTextTab(textAlignment: .left, location: 14),
                      NSTextTab(textAlignment: .left, location: kArrowX),
                      NSTextTab(textAlignment: .left, location: kConnX),
                      NSTextTab(textAlignment: .right, location: kColorX)]   // 右对齐，右侧留白和左边对称
    style.defaultTabInterval = 0

    let s = NSMutableAttributedString()
    // 圆点画在标题最前面（不用 item.image，避免图标槽造成缩进）
    // ★ 每行都以一个字符开头再 tab：行首直接写 tab 时 AppKit 会吞掉，
    //   导致选中行(有●)和未选中行(无●)的名字起点不一致。
    s.append(NSAttributedString(string: dot ? "●" : " ", attributes: [
        .font: NSFont.systemFont(ofSize: 8),
        .foregroundColor: dot ? NSColor.controlAccentColor : NSColor.clear,
        .baselineOffset: 2,
        .paragraphStyle: style]))
    s.append(NSAttributedString(string: "\t" + cn, attributes: [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: style]))
    s.append(NSAttributedString(string: "\t" + arrow, attributes: [
        .font: NSFont.systemFont(ofSize: 11.5),
        .foregroundColor: NSColor.tertiaryLabelColor,
        .paragraphStyle: style]))
    s.append(NSAttributedString(string: "\t" + conn, attributes: [
        .font: NSFont.systemFont(ofSize: 11.5),
        .foregroundColor: NSColor.secondaryLabelColor,
        .paragraphStyle: style]))
    s.append(NSAttributedString(string: "\t" + color, attributes: [
        .font: NSFont.systemFont(ofSize: 12),
        .foregroundColor: jackColor(color),
        .paragraphStyle: style]))
    return s
}

/// tooltip：中文全称 + 颜色 + 位置
func panelHint(index: Int, isInput: Bool) -> String {
    if isInput {
        switch index {
        case 0: return "后置麦克风 · 粉色 3.5mm 插孔"
        case 1: return "前置麦克风 · 粉色 3.5mm 插孔"
        case 2: return "后置线路输入 · 蓝色 3.5mm 插孔"
        default: return ""
        }
    } else {
        switch index {
        case 3: return "后置线路输出 · 绿色 3.5mm 插孔"
        case 4: return "前置耳机 · 绿色 3.5mm 插孔"
        case 5: return "光纤数字输出 · 方口"
        default: return ""
        }
    }
}

// MARK: - 自绘菜单行（用 NSMenuItem.view，点击不关闭菜单）

final class RowView: NSView {
    var title: NSAttributedString { didSet { needsDisplay = true } }
    let dev: AudioDev
    let onClick: () -> Void
    private var hover = false { didSet { needsDisplay = true } }

    init(dev: AudioDev, title: NSAttributedString, onClick: @escaping () -> Void) {
        self.dev = dev
        self.title = title
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { hover = true }
    override func mouseExited(with e: NSEvent)  { hover = false }
    override func mouseDown(with e: NSEvent)    { onClick() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        if hover {
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        // ★ 普通菜单项的文字有 ~14pt 左边距（勾选槽），view 项没有。
        //   这里补上同样的偏移，才能和「输出设备」标题、底部三项对齐。
        title.draw(at: NSPoint(x: 18, y: (bounds.height - title.size().height) / 2))
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var vrefTimer: Timer?

    /// true = 音量条控制输入（麦克风图标），false = 控制输出（喇叭图标）
    var isInputMode: Bool = UserDefaults.standard.bool(forKey: "AudioBar.inputMode") {
        didSet { UserDefaults.standard.set(isInputMode, forKey: "AudioBar.inputMode") }
    }
    weak var volSlider: NSSlider?
    weak var volIcon: NSButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = makeStatusItem()
        menu.delegate = self
        statusItem.menu = menu

        // --selftest：延迟 1.5s 再测（NSStatusBar 的布局要等下一轮 runloop，
        // 立即读 window.frame 会得到高度 0 的假结果），测完写文件并退出
        if CommandLine.arguments.contains("--selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                guard let item = self.statusItem else { exit(0) }
                var out = ""
                func log(_ k: String, _ v: Any) { out += "\(k) = \(v)\n" }
                log("button", item.button != nil)
                log("image", item.button?.image?.size ?? .zero)
                log("isVisible", item.isVisible)
                log("button.frame", item.button?.frame ?? .zero)
                if let w = item.button?.window {
                    log("window.frame", w.frame)
                    log("window.visible", w.isVisible)
                    log("onScreen", NSScreen.screens.contains { $0.frame.intersects(w.frame) })
                }
                log("screen", NSScreen.main?.frame ?? .zero)
                log("screens", NSScreen.screens.map { $0.frame })
                log("menuBarHeight", NSStatusBar.system.thickness)
                // 图标到底有没有像素？（空白图标 = 一切参数正常但看不见）
                if let img = item.button?.image {
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                               pixelsWide: Int(img.size.width * 2), pixelsHigh: Int(img.size.height * 2),
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                               isPlanar: false, colorSpaceName: .deviceRGB,
                                               bytesPerRow: 0, bitsPerPixel: 0)
                    if let rep = rep {
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                        img.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
                        NSGraphicsContext.restoreGraphicsState()
                        var ink = 0
                        for y in 0..<rep.pixelsHigh {
                            for x in 0..<rep.pixelsWide {
                                if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.05 { ink += 1 }
                            }
                        }
                        log("image.reps", img.representations.count)
                        log("image.isTemplate", img.isTemplate)
                        log("image.inkPixels", "\(ink) / \(rep.pixelsWide * rep.pixelsHigh)")
                    }
                }
                try? out.write(toFile: "/tmp/audioswitch-selftest.txt", atomically: true, encoding: .utf8)
                exit(0)
            }
        }

        // ★ 首次补偏置必须放到后台队列：
        //   它会同步 fork alc-verb 并 waitUntilExit，阻塞主线程几百毫秒。
        //   在这期间 NSStatusBar 来不及布局，NSStatusItem 会被丢到菜单栏最左端
        //   （x=0，被苹果菜单盖住）⇒ 表现为"菜单栏看不到图标"，且是间歇性的。
        if ProcessInfo.processInfo.environment["AS_NO_VREF"] == nil {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.applyFrontMicVref()
            }
        }
        // 每 120 秒补一次前置麦克风偏置（AppleHDA 会覆盖）
        vrefTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.applyFrontMicVref(silent: true)
        }
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 菜单栏图标：SF Symbol 取系统标准尺寸（WiFi/蓝牙同规格），模板图自动反色
        let symCfg = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .semibold)
        if let img = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "音频切换")?
            .withSymbolConfiguration(symCfg) {
            img.isTemplate = true
            item.button?.image = img
        } else {
            item.button?.title = "音频"
        }
        item.button?.toolTip = "音频输出 / 输入切换"
        return item
    }

    /// 图标真的在菜单栏里吗？不在就重建状态栏项
    private func verifyPlacement(retries: Int) {
        guard retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            guard let w = self.statusItem.button?.window else { return }
            // 菜单栏 = 屏幕 visibleFrame 上沿之上那条带
            let inMenuBar = NSScreen.screens.contains { scr in
                w.frame.minY >= scr.visibleFrame.maxY - 4 && scr.frame.contains(NSPoint(x: w.frame.midX, y: w.frame.midY))
            }
            if inMenuBar { return }
            NSStatusBar.system.removeStatusItem(self.statusItem)
            self.statusItem = self.makeStatusItem()
            self.statusItem.menu = self.menu
            self.verifyPlacement(retries: retries - 1)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    func rebuildMenu() {
        menu.removeAllItems()
        let devs = allAudioDevices()
        let curOut = defaultDevice(false)
        let curIn = defaultDevice(true)

        menu.addItem(volumeItem())
        menu.addItem(.separator())
        menu.addItem(header("输出设备"))
        for d in devs.filter({ !$0.isInput }).sorted(by: { sortRank(index: $0.index, isInput: false) < sortRank(index: $1.index, isInput: false) }) {
            menu.addItem(deviceItem(d, current: curOut))
        }

        menu.addItem(.separator())
        menu.addItem(header("输入设备"))
        for d in devs.filter({ $0.isInput }).sorted(by: { sortRank(index: $0.index, isInput: true) < sortRank(index: $1.index, isInput: true) }) {
            menu.addItem(deviceItem(d, current: curIn))
        }

        menu.addItem(.separator())
        let open = NSMenuItem(title: "声音设置…", action: #selector(openSoundPrefs), keyEquivalent: "")
        open.target = self
        open.attributedTitle = plainTitle("声音设置…")
        menu.addItem(open)

        let auto = NSMenuItem(title: "登录时启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        auto.target = self
        auto.state = .off                       // 不用系统对号
        auto.attributedTitle = plainTitle("登录时启动", dot: isLaunchAtLoginEnabled())
        auto.toolTip = "开机后自动运行 AudioSwitch（在系统设置 → 通用 → 登录项 里可见）"
        menu.addItem(auto)

        menu.addItem(.separator())
        // 用自己的 action，避免系统给标准 terminate 项加图标
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        quit.image = nil
        quit.attributedTitle = plainTitle("退出")
        menu.addItem(quit)
    }

    /// 音量行：图标(喇叭/麦克风，可点静音) + 滑块 + 百分比
    private func volumeItem() -> NSMenuItem {
        let item = NSMenuItem()
        let w: CGFloat = 196, h: CGFloat = 34     // 组件整体收窄（原 220）
        let box = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        let dev = defaultDevice(isInputMode)
        let vol = getVolume(dev, input: isInputMode)
        let muted = getMute(dev, input: isInputMode) ?? false
        let canVol = (vol != nil)

        // 左右各留 inset，图标 / 滑块 / 百分比之间的间隙统一为 gap
        let inset: CGFloat = 12
        let gap: CGFloat = 4     // 滑块贴近图标和百分比，换取更长
        let btn = NSButton(frame: NSRect(x: inset, y: (h - 22) / 2, width: 22, height: 22))
        btn.isBordered = false
        btn.imagePosition = .imageOnly
        btn.image = volIconImage(muted: muted)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        btn.contentTintColor = !canVol ? .tertiaryLabelColor
                             : (muted ? .controlAccentColor : .secondaryLabelColor)
        btn.isEnabled = canVol
        btn.target = self
        btn.action = #selector(toggleMute)
        box.addSubview(btn)
        volIcon = btn

        let pctW: CGFloat = 36
        let pctX = w - inset - pctW
        let sx = inset + 22 + gap
        // 滑块和图标同高（22）且同一中心线，避免视觉上不齐
        let slider = NSSlider(frame: NSRect(x: sx, y: (h - 22) / 2,
                                            width: max(20, pctX - gap - sx), height: 22))
        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true
        slider.doubleValue = Double(vol ?? 0)
        slider.isEnabled = canVol
        slider.target = self
        slider.action = #selector(volumeChanged(_:))
        box.addSubview(slider)
        volSlider = slider

        let pct = NSTextField(labelWithString: canVol ? "\(Int(((vol ?? 0) * 100).rounded()))%" : "—")
        pct.frame = NSRect(x: pctX, y: (h - 15) / 2, width: pctW, height: 15)
        pct.alignment = .right
        pct.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        pct.textColor = canVol ? .secondaryLabelColor : .tertiaryLabelColor
        pct.tag = 99
        box.addSubview(pct)

        item.view = box
        return item
    }

    /// 输出用喇叭，输入用麦克风
    private func volIconImage(muted: Bool) -> NSImage? {
        let name: String
        if isInputMode { name = muted ? "mic.slash.fill" : "mic.fill" }
        else           { name = muted ? "speaker.slash.fill" : "speaker.fill" }
        return NSImage(systemSymbolName: name, accessibilityDescription: "静音")
    }

    /// 按当前默认设备刷新音量条的数值/图标/可用状态
    private func refreshVolumeRow() {
        let dev = defaultDevice(isInputMode)
        let vol = getVolume(dev, input: isInputMode)
        let muted = getMute(dev, input: isInputMode) ?? false
        let canVol = (vol != nil)
        volSlider?.doubleValue = Double(vol ?? 0)
        volSlider?.isEnabled = canVol
        if let pct = volSlider?.superview?.viewWithTag(99) as? NSTextField {
            pct.stringValue = canVol ? "\(Int(((vol ?? 0) * 100).rounded()))%" : "—"
            pct.textColor = canVol ? .secondaryLabelColor : .tertiaryLabelColor
        }
        volIcon?.isEnabled = canVol
        volIcon?.image = volIconImage(muted: muted)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        volIcon?.contentTintColor = !canVol ? .tertiaryLabelColor
                                 : (muted ? .controlAccentColor : .secondaryLabelColor)
    }

    @objc func volumeChanged(_ sender: NSSlider) {
        let dev = defaultDevice(isInputMode)
        setVolume(dev, Float(sender.doubleValue), input: isInputMode)
        if sender.doubleValue > 0.001, getMute(dev, input: isInputMode) == true {
            setMute(dev, false, input: isInputMode)
        }
        if let pct = volSlider?.superview?.viewWithTag(99) as? NSTextField {
            pct.stringValue = "\(Int((sender.doubleValue * 100).rounded()))%"
        }
        refreshVolIcon()
    }

    @objc func toggleMute() {
        let dev = defaultDevice(isInputMode)
        setMute(dev, !(getMute(dev, input: isInputMode) ?? false), input: isInputMode)
        refreshVolIcon()
    }

    private func refreshVolIcon() {
        let muted = getMute(defaultDevice(isInputMode), input: isInputMode) ?? false
        volIcon?.image = volIconImage(muted: muted)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        volIcon?.contentTintColor = muted ? .controlAccentColor : .secondaryLabelColor
    }

    private func header(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.labelColor])
        return item
    }

    private func deviceItem(_ d: AudioDev, current: AudioDeviceID) -> NSMenuItem {
        let item = NSMenuItem()
        let v = RowView(dev: d, title: rowTitle(d, current: current)) { [weak self] in
            self?.selectDeviceDirect(d)
        }
        v.frame = NSRect(x: 0, y: 0, width: 196, height: 26)   // 与系统菜单项高度一致
        item.view = v
        item.toolTip = panelHint(index: d.index, isInput: d.isInput)
        return item
    }

    /// 一行的标题（含圆点）
    private func rowTitle(_ d: AudioDev, current: AudioDeviceID) -> NSAttributedString {
        let active = (d.id == current)
        if let c = columns(for: d) {
            return alignedTitle(c.0, c.1, c.2, c.3, dot: active)
        }
        return plainTitle(d.name, dot: active)
    }

    /// 点行：切设备 + 就地刷新所有行的圆点（不重建菜单 ⇒ 菜单不关闭）
    private func selectDeviceDirect(_ d: AudioDev) {
        _ = setDefault(d.id, input: d.isInput)
        isInputMode = d.isInput
        let curOut = defaultDevice(false)
        let curIn = defaultDevice(true)
        for item in menu.items {
            guard let v = item.view as? RowView else { continue }
            v.title = rowTitle(v.dev, current: v.dev.isInput ? curIn : curOut)
        }
        refreshVolumeRow()      // 音量条跟着切到新设备的音量
    }

    @objc func selectDevice(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let raw = info["id"] as? Int,
              let input = info["input"] as? Bool else { return }
        _ = setDefault(AudioDeviceID(raw), input: input)
        isInputMode = input          // 音量条跟着切到对应的作用域
        rebuildMenu()
    }

    // MARK: 开机自启动（SMAppService，macOS 13+）

    func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else {
            showAlert("需要 macOS 13 或更高版本", "SMAppService 在 macOS 12 及更早不可用。")
            return
        }
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
            } else {
                try svc.register()
            }
        } catch {
            showAlert("设置失败", error.localizedDescription)
        }
        rebuildMenu()
    }

    func showAlert(_ title: String, _ msg: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = msg
        a.alertStyle = .warning
        a.runModal()
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    @objc func openSoundPrefs() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 给前置麦克风（0x19）补 VREF 80%
    func applyFrontMicVref(silent: Bool = false) {
        guard let helper = Bundle.main.path(forResource: "alc-verb", ofType: nil) else {
            if !silent { NSLog("alc-verb 未打包进 app") }
            return
        }
        let read = Process()
        read.executableURL = URL(fileURLWithPath: helper)
        read.arguments = ["0x19", "0xF07", "0x00"]
        let pipe = Pipe()
        read.standardOutput = pipe
        read.standardError = FileHandle.nullDevice
        do { try read.run() } catch { return }
        read.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if out.contains("0x00000024") { return }   // 已经是 IN + VREF 80%

        let set = Process()
        set.executableURL = URL(fileURLWithPath: helper)
        set.arguments = ["0x19", "0x707", "0x24"]
        set.standardOutput = FileHandle.nullDevice
        set.standardError = FileHandle.nullDevice
        do { try set.run() } catch { return }
        set.waitUntilExit()
        if !silent { NSLog("已为前置麦克风补 VREF 80%") }
    }
}

// MARK: - 启动

let app = NSApplication.shared
// ★ 不再调用 setActivationPolicy(.accessory)：Info.plist 里的 LSUIElement 已经
//   让 app 从一开始就是 accessory。再调一次会产生「策略切换」，
//   切换期间菜单栏重排，NSStatusItem 会被丢到 x=0（被苹果菜单盖住）→ 看不到图标。
let delegate = AppDelegate()
app.delegate = delegate

// 开机自启动的 CLI 控制
if CommandLine.arguments.contains("--autostart-status") {
    if #available(macOS 13.0, *) {
        print("开机自启动: \(SMAppService.mainApp.status == .enabled ? "已开启" : "未开启")")
    } else {
        print("开机自启动: 需要 macOS 13+")
    }
    exit(0)
}
if CommandLine.arguments.contains("--enable-autostart") {
    guard #available(macOS 13.0, *) else { print("需要 macOS 13+"); exit(1) }
    do { try SMAppService.mainApp.register(); print("开机自启动已开启") }
    catch { print("开启失败: \(error.localizedDescription)"); exit(1) }
    exit(0)
}
if CommandLine.arguments.contains("--disable-autostart") {
    guard #available(macOS 13.0, *) else { print("需要 macOS 13+"); exit(1) }
    do { try SMAppService.mainApp.unregister(); print("开机自启动已关闭") }
    catch { print("关闭失败: \(error.localizedDescription)"); exit(1) }
    exit(0)
}

// --pins：打印 codec 引脚颜色与推导结果（验证取色是否和硬编码表一致）
if CommandLine.arguments.contains("--pins") {
    print("codec 引脚 (deviceType, 颜色)：")
    for (t, c) in codecPinColors() { print("  type=\(t)  \(c)") }
    print("\n逐设备推导：")
    for d in allAudioDevices() {
        let derived = derivedColumns(name: d.name, isInput: d.isInput)
        let exact = panelColumns(index: d.index, isInput: d.isInput)
        print("  \(d.isInput ? "输入" : "输出") idx=\(d.index)  \(d.name)")
        print("     精确表颜色 = \(exact?.3 ?? "-")   推导颜色 = \(derived?.3 ?? "-")")
    }
    exit(0)
}

// --dump：不启动界面，只打印菜单会显示的内容（用于核对名称映射）
if CommandLine.arguments.contains("--dump") {
    let devs = allAudioDevices()
    let curOut = defaultDevice(false)
    let curIn = defaultDevice(true)
    func line(_ d: AudioDev, _ cur: AudioDeviceID) -> String {
        let mark = d.id == cur ? "●" : "○"
        guard let c = columns(for: d) else {
            return "  \(mark) \(d.name)  [idx=\(d.index)]"
        }
        return "  \(mark) \(c.0.padding(toLength: 14, withPad: " ", startingAt: 0))"
             + "\(c.1) \(c.2)".padding(toLength: 14, withPad: " ", startingAt: 0) + "\(c.3)"
    }
    print("输出设备（当前默认 id=\(curOut)）")
    for d in devs.filter({ !$0.isInput }).sorted(by: { sortRank(index: $0.index, isInput: false) < sortRank(index: $1.index, isInput: false) }) {
        print(line(d, curOut))
    }
    print("输入设备（当前默认 id=\(curIn)）")
    for d in devs.filter({ $0.isInput }).sorted(by: { sortRank(index: $0.index, isInput: true) < sortRank(index: $1.index, isInput: true) }) {
        print(line(d, curIn))
    }
    exit(0)
}

app.run()
