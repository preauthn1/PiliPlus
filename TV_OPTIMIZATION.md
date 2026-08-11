# PiliPlus Android TV 优化

## 概述
本分支为 PiliPlus 添加了 Android TV 支持，使应用能在电视和机顶盒上运行并提供优化的遥控器体验。

## 主要改动

### 1. Android TV 清单配置
**文件：** `android/app/src/main/AndroidManifest.xml`

- 添加 `LEANBACK_LAUNCHER` category 使应用出现在 TV 启动器
- 添加 `android:banner` 属性用于 TV 界面展示
- 声明 `touchscreen` 为非必需（`required="false"`）
- 添加 `android.software.leanback` feature 声明

### 2. TV 设备检测
**文件：** 
- `lib/utils/platform_utils.dart` - 添加 `isTV` 和 `isAndroidTV` 检测
- `android/app/src/main/kotlin/com/example/piliplus/MainActivity.kt` - 原生层 TV 检测
- `lib/main.dart` - 启动时检测并设置 TV 模式

通过 `UiModeManager` 检测设备是否为 Android TV，并通过 MethodChannel 传递给 Flutter。

```dart
// 使用方式
if (PlatformUtils.isTV) {
  // TV 专用逻辑
}
```

### 3. TV 焦点组件
**新增文件：** `lib/common/widgets/tv_card.dart`

提供 TV 优化的卡片组件，特性：
- D-Pad 方向键导航
- 遥控器 OK/Select 按钮处理
- 焦点状态视觉反馈（3px 边框高亮 + 缩放动画）
- 自动适配移动端和 TV 端（移动端不显示焦点效果）

### 4. 已有的键盘支持
项目已有完善的键盘快捷键支持（`lib/pages/video/widgets/player_focus.dart`）：
- 空格：播放/暂停
- F：全屏切换
- D：弹幕开关
- M：静音
- 方向键：音量、快进快退
- Enter：发送弹幕

这些快捷键同样适用于 TV 遥控器，无需额外适配。

## 使用示例

### 包装现有组件为 TV 友好组件

```dart
import 'package:PiliPlus/common/widgets/tv_card.dart';

// 移动端组件
Card(
  child: VideoItem(...),
  onTap: () => navigateToVideo(),
)

// TV 优化后
TVCard(
  autofocus: index == 0, // 首个元素自动获取焦点
  onTap: () => navigateToVideo(),
  child: VideoItem(...),
)
```

### 条件渲染 TV UI

```dart
import 'package:PiliPlus/utils/platform_utils.dart';

Widget build(BuildContext context) {
  if (PlatformUtils.isTV) {
    // TV 专用大按钮 UI
    return buildTVLayout();
  }
  // 移动端 UI
  return buildMobileLayout();
}
```

## 构建和测试

### 构建 TV APK
```bash
cd /tmp/PiliPlus-clean
flutter build apk --release
# 或针对 ARM64
flutter build apk --release --target-platform android-arm64
```

### 在 Android TV 模拟器测试
1. Android Studio 创建 TV AVD（API 28+）
2. 运行：`flutter run`
3. 使用模拟器的 D-Pad 控制器测试导航

### 在真实设备测试
推荐设备：
- 小米盒子
- NVIDIA Shield TV  
- Google Chromecast with Google TV
- 品牌智能电视（Android TV 系统）

## 后续优化方向

### 高优先级
- [ ] 首页视频列表使用 TVCard 包装
- [ ] 播放器界面 10ft UI 模式（更大的控制按钮）
- [ ] 搜索界面适配遥控器输入
- [ ] 设置界面 TV 导航优化

### 中优先级
- [ ] 登录流程 TV 适配（扫码或遥控器输入）
- [ ] 弹幕发送界面虚拟键盘优化
- [ ] 个人中心 TV 布局
- [ ] 收藏夹网格布局优化

### 低优先级
- [ ] TV 专用主题色
- [ ] 语音搜索支持（Android TV 原生）
- [ ] 画中画模式优化
- [ ] 多账号切换 TV UI

## 兼容性

- **最低 Android 版本：** Android 5.0 (API 21)
- **推荐 Android 版本：** Android 9.0+ (API 28+)
- **向后兼容：** 所有改动不影响现有移动端体验
- **Flutter 版本：** 3.24.8+, Dart 3.12.0+

## 参考资料

- [Android TV 开发指南](https://developer.android.com/training/tv)
- [Leanback 库文档](https://developer.android.com/reference/androidx/leanback/package-summary)
- [Flutter TV 应用最佳实践](https://docs.flutter.dev/platform-integration/android/tv)

---

**日期：** 2026-08-11  
**基于版本：** PiliPlus commit e5dfc6394
