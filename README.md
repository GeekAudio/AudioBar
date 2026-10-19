# AudioBar

macOS 菜单栏音频切换工具。黑苹果（AppleALC）环境下可显示**插孔真实颜色和接口类型**。

## 功能

- **三栏显示**：中文名 / 方向符号 + 接口名 / 插孔图标
- **音量条**：输出模式显示喇叭图标，输入模式显示麦克风图标，可拖动、可点图标静音
- **切换设备时菜单不关闭**（设备行用 `NSMenuItem.view` 自绘）
- **插孔图标**：3.5mm 圆孔 / 光纤方口，自绘，按插孔颜色染色
- **开机自启动**（SMAppService）
- 麦克风偏置自动补正（每 120 秒，针对 ALC897 前置麦克风）

## 兼容性

| 部分 | 说明 |
|---|---|
| 设备切换 / 音量 / 静音 | **通用**，任何 Mac 都能用 |
| 插孔名称和颜色 | **按 codec 引擎序号映射**，默认适配 ALC897 layout 14 |
| 其他 codec | 自动回退：从系统设备名推导中文名（`Built-in Line Output` → 线路输出），颜色和图标为空 |

换机器后如果名称不对，改 `main.swift` 里的 `panelColumns()` 即可。

## 安装

下载 [Releases](https://github.com/GeekAudio/AudioBar/releases) 里的 dmg，拖到「应用程序」。

首次打开被 Gatekeeper 拦时：**右键 → 打开**，或执行

```bash
xattr -dr com.apple.quarantine /Applications/AudioBar.app
```

## 命令行

```bash
/Applications/AudioBar.app/Contents/MacOS/AudioSwitch --dump              # 打印菜单内容
/Applications/AudioBar.app/Contents/MacOS/AudioSwitch --autostart-status  # 查看开机自启动
/Applications/AudioBar.app/Contents/MacOS/AudioSwitch --enable-autostart
/Applications/AudioBar.app/Contents/MacOS/AudioSwitch --disable-autostart
```

## 构建

```bash
bash tools/build-audiobar.sh            # 只编译
bash tools/build-audiobar.sh --install  # 编译 + 部署到 /Applications
```

需要 Xcode 命令行工具。
