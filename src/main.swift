import Cocoa
import CoreAudio
import ServiceManagement

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
let kArrowX: CGFloat = 66
let kConnX: CGFloat  = 84
let kColorX: CGFloat = 128

/// 颜色字用真实颜色渲染，不用读就知道是哪个口
func jackColor(_ c: String) -> NSColor {
    switch c {
    case "绿":   return NSColor(srgbRed: 0.13, green: 0.62, blue: 0.24, alpha: 1)
    case "粉":   return NSColor(srgbRed: 0.85, green: 0.28, blue: 0.55, alpha: 1)
    case "蓝":   return NSColor(srgbRed: 0.11, green: 0.44, blue: 0.85, alpha: 1)
    default:    return NSColor.secondaryLabelColor
    }
}

/// 小圆点：用来标记当前设备（代替系统对号）
func dotImage(diameter: CGFloat = 7, color: NSColor = .controlAccentColor) -> NSImage {
    let img = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
        color.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
        return true
    }
    img.isTemplate = false
    return img
}

/// 全透明占位图：让所有菜单项的图标槽宽度一致，标题才不会左右错位
func blankImage(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in true }
}

/// 中文 13pt 主色 / 方向符号 11.5pt 三级灰 / 接口名 11.5pt 次要灰 / 颜色字用插孔真实颜色
func alignedTitle(_ cn: String, _ arrow: String, _ conn: String, _ color: String) -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.tabStops = [NSTextTab(textAlignment: .left, location: kArrowX),
                      NSTextTab(textAlignment: .left, location: kConnX),
                      NSTextTab(textAlignment: .left, location: kColorX)]
    style.defaultTabInterval = 0

    let s = NSMutableAttributedString()
    s.append(NSAttributedString(string: cn, attributes: [
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

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var vrefTimer: Timer?

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
        menu.addItem(open)

        let auto = NSMenuItem(title: "登录时启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        auto.target = self
        auto.state = isLaunchAtLoginEnabled() ? .on : .off
        auto.toolTip = "开机后自动运行 AudioSwitch（在系统设置 → 通用 → 登录项 里可见）"
        menu.addItem(auto)

        menu.addItem(.separator())
        // 用自己的 action，避免系统给标准 terminate 项加图标
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        quit.image = nil
        menu.addItem(quit)
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
        let item = NSMenuItem(title: d.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ["id": Int(d.id), "input": d.isInput]
        // 用实心小圆点代替系统对号；未选中的用透明占位，保证标题起点一致
        let active = (d.id == current)
        item.state = .off
        item.image = active ? dotImage() : blankImage(size: 7)

        if let c = panelColumns(index: d.index, isInput: d.isInput) {
            item.attributedTitle = alignedTitle(c.0, c.1, c.2, c.3)
        }
        let hint = panelHint(index: d.index, isInput: d.isInput)
        item.toolTip = (hint.isEmpty ? "" : hint + "　") + d.name
        return item
    }

    @objc func selectDevice(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let raw = info["id"] as? Int,
              let input = info["input"] as? Bool else { return }
        _ = setDefault(AudioDeviceID(raw), input: input)
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

// --dump：不启动界面，只打印菜单会显示的内容（用于核对名称映射）
if CommandLine.arguments.contains("--dump") {
    let devs = allAudioDevices()
    let curOut = defaultDevice(false)
    let curIn = defaultDevice(true)
    func line(_ d: AudioDev, _ cur: AudioDeviceID) -> String {
        let mark = d.id == cur ? "●" : "○"
        guard let c = panelColumns(index: d.index, isInput: d.isInput) else {
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
