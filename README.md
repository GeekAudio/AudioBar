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
/Applications/AudioBar.app/Contents/MacOS/AudioSwitch --pins              # 打印 codec 引脚与推导结果
/Applications/AudioBar.app/Contents/MacOS/AudioSwitch --autostart-status  # 查看开机自启动
/Applications/AudioBar.app/Contents/MacOS/AudioSwitch --enable-autostart
/Applications/AudioBar.app/Contents/MacOS/AudioSwitch --disable-autostart
```

## 构建

```bash
bash tools/build-audiobar.sh            # 只编译，产出 ./AudioBar.app
bash tools/build-audiobar.sh --install  # 编译 + 部署到 /Applications
```

需要 Xcode 命令行工具。`alc-verb` 是可选的（只影响麦克风偏置这一项）：

```bash
ALC_VERB=/path/to/AppleALC/build/Release/alc-verb bash tools/build-audiobar.sh
```

## 更新记录

### v1.2

修好「按 codec 自动推导插孔颜色 / 接口类型」——这条在 v1.1 里实际是**完全没生效**的
（`--pins` 里引脚列表为空，一直靠硬编码表兜底）。

| # | 问题 | 修法 |
|---|---|---|
| 1 | `HDAConfigDefault` 用 `as? Data` 读不到 | 实际是字典数组，读 `BootConfigData` |
| 2 | 遍历深度限制 `depth < 3` 太浅 | 属性在控制器下第 4~5 层 → 改 8 |
| 3 | `bindMemory(to: UInt32.self)` 把大端 verb 读反 | 改逐字节按大端拼 |
| 4 | 用 bit31 判「有插孔」 | bit31 是 PortConnectivity 高位，插孔 `00b` 反而为 0 → 改判 `(v>>30)&3 != 01b` |
| 5 | `derivedColumns()` 只在 SPDIF 分支用颜色 | 其他分支硬编码空串 → 全部改用推导值 |
| 6 | 要求引脚数 == 设备数才配对 | 板载常不暴露 REAR / C-SUB → 放宽为「引脚 ≥ 设备」取前 N |

字段表按 Hackintool（[benbaker76/Hackintool](https://github.com/benbaker76/Hackintool)，
`NSColor+Pin.m` / `NSString+Pin.m`）对齐：

- 颜色补上 `14 = 白`、`15 = 其他`
- 用 `Connection Type = 5 (Optical)` 权威判定光纤口，不再靠设备名猜
- `Port Connectivity`：跳过 `01b = No Connection`

另：`tools/build-audiobar.sh` 随仓库提供，不再需要外部脚本。
