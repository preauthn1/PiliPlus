# PiliPlus Android TV 优化

## 概述
本分支为 PiliPlus 添加 Android TV 支持，使应用能在电视和机顶盒上运行，
并可用物理遥控器（D-Pad）正常操作。

## 主要改动

### 1. Android TV 清单配置
**文件：** `android/app/src/main/AndroidManifest.xml`

- 添加 `LEANBACK_LAUNCHER` category 使应用出现在 TV 启动器
- 添加 `android:banner` 属性用于 TV 界面展示
- 声明 `touchscreen` 为非必需（`required="false"`）
- 添加 `android.software.leanback` feature 声明

### 2. TV 设备检测（已加固）
**文件：**
- `android/.../MainActivity.kt` — 原生检测
- `lib/utils/platform_utils.dart` — `isTV` / `isAndroidTV`
- `lib/main.dart` — 启动时检测

仅靠 `UiModeManager` 判断并不可靠：大量国产电视盒子/投影会返回
`UI_MODE_TYPE_NORMAL`。现在改为多重判定，任一命中即视为 TV：

1. `UiModeManager.currentModeType == UI_MODE_TYPE_TELEVISION`
2. `FEATURE_LEANBACK`
3. `android.hardware.type.television`
4. 无 `FEATURE_TOUCHSCREEN`

同时修正了时序问题：TV 检测现在**保证在方向设置之前完成**。

### 3. 方向锁定修复（关键）
此前 `main.dart` 无条件走 `Pref.horizontalScreen ? fullMode() : portraitUpMode()`，
而 `horizontalScreen` 默认值取自 `DeviceUtils.isTablet`——电视盒子不算平板，
于是电视被**强制锁竖屏**，画面横躺、方向键映射错乱。

现在：
- `main.dart` 在 TV 上走 `landscapeLeftMode()`
- `Pref.horizontalScreen` 在 TV 上直接返回 `true`，
  使播放器内部横屏逻辑一致

### 4. D-Pad 焦点系统（关键）
**新增：** `lib/common/widgets/tv_focus_scope.dart`

这是「遥控器怎么按都没反应」的真正根因：应用冷启动后
`FocusManager.primaryFocus` 为 **null**，方向键没有可遍历的起点，
OK 键也没有作用对象，所以按任何键都毫无反应。

`TVFocusScope` 负责：
- 启动后播下焦点「种子」，让 D-Pad 有起点（带重试，等异步页面构建完成）
- 任何时刻焦点为空时，按下方向键会先重新播种并吞掉该次按键，
  下一次按键即可正常移动——避免路由切换后再次「按不动」
- 补充映射部分遥控器发出的 `gameButtonA`（Flutter 默认快捷键表未覆盖）

> Flutter 默认的 `ReadingOrderTraversalPolicy` 已混入
> `DirectionalFocusTraversalPolicyMixin`，方向遍历本身可用；
> 且 `Scrollable.ensureVisible` 会自动把获得焦点的项滚入可视区，
> 因此无需自定义遍历策略。

### 5. 焦点可见性
**文件：** `lib/common/widgets/tv_card.dart`（`TVFocusHighlight`）、
`lib/utils/theme_utils.dart`

原 `TVCard` 需要改写所有调用点，因此**从未被任何地方使用**，属于死代码。
现改为装饰型组件 `TVFocusHighlight`，包在现有卡片外层即可，
不创建自己的焦点节点（`canRequestFocus: false`），
不会与内部 `InkWell` 争抢焦点或产生重复停靠点。

已接入：`video_card_h.dart`、`video_card_v.dart`。

同时在主题层为 TV 设置了高对比 `focusColor`，
使所有基于 `InkWell` 的控件获得焦点时都有明显反馈。

### 6. 手机遥控入口
`/tvRemote` 路由此前只注册、无任何入口可达。现已在
**设置 → 其他设置 → 手机遥控** 中暴露（仅 TV 可见）。

详见 `TV_WEB_REMOTE.md`。

### 7. 已有的键盘支持
项目已有完善的键盘快捷键（`lib/pages/video/widgets/player_focus.dart`）：
空格播放/暂停、F 全屏、D 弹幕、M 静音、方向键音量与快进快退、Enter 发弹幕。
这些同样适用于 TV 遥控器。

## 验证

```bash
flutter analyze lib/          # 相对基线无新增问题
flutter test test/tv_remote_e2e_test.dart   # 13 项端到端通过
```

APK 由 GitHub Actions 构建（本机内存不足以跑 release 构建）。

## 仍待完善

- TV 专用布局（更大字号、更宽间距、首屏栅格）尚未做，
  当前仍复用手机布局，仅焦点与方向已可用
- 手机端扫码登录未实现
