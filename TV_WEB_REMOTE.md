# PiliPlus TV Web 遥控器

## 功能概述

在 Android TV 上运行 PiliPlus 时，自动启动一个内置 Web 服务器（默认 8888 端口），允许用户通过手机浏览器远程控制电视、登录账号、调整设置。

## 使用流程

### 1. 在电视上打开遥控面板

在 PiliPlus TV 应用中，导航到 **设置 → TV 遥控器** 或直接访问路由 `/tvRemote`，会显示：

- **二维码**：手机扫码即可快速连接
- **局域网地址**：例如 `http://192.168.1.100:8888`
- **使用说明**：登录、控制、设置三步指引

### 2. 手机连接

确保手机和电视在**同一 WiFi 网络**下，然后：

- **扫码**：使用手机相机或微信扫描电视上的二维码
- **手动输入**：在手机浏览器输入显示的地址（如 `http://192.168.1.100:8888`）

### 3. Web 控制界面功能

手机浏览器打开后，提供以下功能：

#### 账号登录
- 扫描 B 站二维码快速登录
- 登录状态实时同步到电视端

#### 播放控制
- 方向键导航（上下左右）
- 播放/暂停
- 音量调节
- 快进/快退（±10秒）
- 返回/主页/搜索快捷键

#### 设置调整
- 画质选择（自动/1080P/720P/480P）
- 弹幕开关
- 音量控制

## 技术实现

### 架构

```
┌─────────────────┐         HTTP/JSON API         ┌─────────────────┐
│   手机浏览器      │ ◄──────────────────────────► │   TV 内置服务器   │
│   (控制端)       │      http://192.168.x.x:8888  │   (被控端)       │
└─────────────────┘                               └─────────────────┘
                                                          │
                                                          ▼
                                                  ┌─────────────────┐
                                                  │  PiliPlus App   │
                                                  │  (Flutter UI)   │
                                                  └─────────────────┘
```

### 核心文件

| 文件 | 作用 |
|------|------|
| `lib/services/tv_remote_server.dart` | HTTP 服务器实现，处理 API 请求 |
| `lib/pages/tv_remote_panel/view.dart` | TV 端显示二维码和地址的界面 |
| `lib/router/app_pages.dart` | 路由注册（`/tvRemote`） |

### API 端点

#### `GET /`
返回完整的 HTML 控制界面（单页应用，无需额外资源）

#### `GET /api/status`
```json
{
  "server": "running",
  "version": "1.0.0",
  "device": "Android TV"
}
```

#### `GET /api/login/qr`
返回 B 站登录二维码 URL（待实现：接入实际 B 站 OAuth 流程）

```json
{
  "qr_url": "https://passport.bilibili.com/qrcode/...",
  "status": "pending"
}
```

#### `POST /api/control`
发送控制指令

**请求体：**
```json
{
  "action": "play_pause"
}
```

**支持的 action：**
- `play_pause` - 播放/暂停
- `volume_up` / `volume_down` - 音量
- `seek_forward` / `seek_backward` - 快进/快退
- `up` / `down` / `left` / `right` - 方向键
- `back` - 返回
- `home` - 主页
- `search` - 搜索

**响应：**
```json
{
  "success": true,
  "action": "play_pause"
}
```

#### `GET /api/settings`
获取当前设置

```json
{
  "volume": 50,
  "quality": "auto",
  "danmaku_enabled": true
}
```

#### `POST /api/settings`
更新设置

**请求体：**
```json
{
  "volume": 60,
  "quality": "1080p"
}
```

## 安全注意事项

### 当前版本（v1.0）
- ⚠️ **无身份验证**：局域网内任何设备都可访问
- ⚠️ **明文传输**：HTTP（非 HTTPS）
- ⚠️ **无加密**：控制指令未加密

### 适用场景
仅用于**家庭局域网**环境，不要暴露到公网。

### 未来改进方向
- [ ] 添加 PIN 码验证（电视显示，手机输入）
- [ ] 生成一次性配对 token
- [ ] HTTPS 支持（自签名证书）
- [ ] WebSocket 实时双向通信
- [ ] 多设备并发控制限制

## 与原生 Android TV 遥控器的区别

| 特性 | Web 遥控器 | Android TV 原生遥控器 |
|------|-----------|---------------------|
| 登录支持 | ✅ 扫码登录 | ❌ 仅导航 |
| 文字输入 | ✅ 手机键盘 | ❌ 虚拟遥控器键盘 |
| 设置调整 | ✅ 直观界面 | ❌ 需要 TV 端操作 |
| 跨品牌兼容 | ✅ 任何手机浏览器 | ❌ 需特定品牌 APP |
| 离线可用 | ✅ 局域网即可 | ❌ 需互联网 + 配对 |

## 开发指南

### 启动服务器

```dart
import 'package:PiliPlus/services/tv_remote_server.dart';

final server = TVRemoteServer.instance;
await server.start(port: 8888);
print('Server URL: ${server.serverURL}');
```

### 监听控制事件

```dart
server.controlStream.listen((action) {
  switch (action) {
    case 'play_pause':
      // 切换播放状态
      break;
    case 'volume_up':
      // 增加音量
      break;
    // ...
  }
});
```

### 停止服务器

```dart
await server.stop();
```

### 自定义端口

```dart
await server.start(port: 9999);
```

## 故障排查

### 手机无法访问

1. **检查网络**：手机和 TV 是否在同一 WiFi？
2. **检查 IP**：TV 显示的 IP 是否为 `127.0.0.1`（错误）或 `192.168.x.x`（正确）？
3. **防火墙**：某些路由器可能隔离设备，尝试关闭 AP 隔离

### 服务启动失败

```dart
// 检查端口占用
final server = TVRemoteServer.instance;
final success = await server.start(port: 8888);
if (!success) {
  // 尝试其他端口
  await server.start(port: 8889);
}
```

### 二维码显示空白

- 检查 `qr_flutter` 依赖是否已安装：`flutter pub get`
- 检查 `serverURL` 是否为 null

## 示例场景

### 场景 1：初次使用
1. 用户在客厅打开 PiliPlus TV 版
2. 进入 **设置 → TV 遥控器**
3. 电视显示二维码和地址 `http://192.168.1.100:8888`
4. 用户用手机微信扫码
5. 手机浏览器打开控制界面
6. 点击"扫码登录"，电视显示 B 站登录二维码
7. 用户用 B 站 APP 扫码，账号登录成功
8. 手机可遥控电视播放视频

### 场景 2：客人来访
1. 客人想在你的电视上播放视频，但不想分享账号
2. 你告诉客人访问 `http://192.168.1.100:8888`
3. 客人用自己的手机登录自己的 B 站账号
4. 客人用手机搜索视频、调整设置
5. 电视上播放客人选择的内容

### 场景 3：卧室控制
1. 躺在床上不想起身拿遥控器
2. 拿出手机访问书签中保存的地址
3. 直接控制播放、音量、快进

## 未来规划

### 短期（v1.1）
- ✅ B 站登录二维码真实对接
- ✅ 播放器控制指令实际绑定
- ✅ 设置同步（音量、画质）

### 中期（v1.2）
- [ ] 搜索功能（手机输入，TV 显示结果）
- [ ] 播放列表管理
- [ ] 历史记录查看
- [ ] 截图功能

### 长期（v2.0）
- [ ] 多设备同时控制
- [ ] 语音输入（手机麦克风）
- [ ] 投屏功能（手机 → TV）
- [ ] 离线模式（手机缓存视频推送到 TV）

---

**版本：** 1.0.0  
**日期：** 2026-08-11  
**维护者：** PiliPlus TV 优化团队
