# PiliPlus TV 手机遥控（Web Remote）

## 概述
在电视端内置一个只监听局域网的小型 HTTP 服务，手机浏览器打开后即可控制电视上的
PiliPlus：方向导航、确定、返回、播放/暂停、音量、快进快退。

入口：**设置 → 其他设置 → 手机遥控**（仅在识别为 TV 的设备上显示）。

## 使用流程
1. 电视上进入「手机遥控」页面，服务自动启动；
2. 页面显示访问地址二维码 + **6 位配对码**；
3. 手机连同一 WiFi，扫码或输入地址打开网页；
4. 在网页中输入电视上显示的配对码，点「连接」；
5. 之后即可用网页上的方向键/OK/播放控制电视。

## 安全模型（v2）
第一版存在严重问题：`InternetAddress.anyIPv4` 全接口监听 + `Access-Control-Allow-Origin: *`
+ 完全无鉴权，任何能访问到该端口的设备、甚至用户浏览的任意网站都能跨域控制电视。

现已修复：

| 措施 | 说明 |
|---|---|
| 局域网校验 | 逐请求校验来源地址，非 RFC1918 / 链路本地 / 回环一律 403 |
| 配对码 | 所有控制类接口需携带 `X-Pairing-Code`，6 位随机码，每次启动服务轮换 |
| CORS 收紧 | 去掉 `Access-Control-Allow-Origin: *`，外部站点无法跨域驱动 |
| 输入校验 | `action` 必须为非空字符串，否则 400 |

`/api/status` 保持免鉴权（仅返回服务存活与「是否需要配对」，不含任何用户数据），
用于手机端确认已连到电视。

## API

| 路径 | 方法 | 鉴权 | 说明 |
|---|---|---|---|
| `/` | GET | 否 | 遥控器网页 |
| `/api/status` | GET | 否 | 服务状态 |
| `/api/control` | POST | **是** | 执行动作 |
| `/api/settings` | GET/POST | **是** | 读取/更新设置 |

请求示例：

```bash
curl -X POST http://<TV_IP>:8888/api/control \
  -H 'Content-Type: application/json' \
  -H 'X-Pairing-Code: 123456' \
  -d '{"action":"play_pause"}'
```

响应中会带回真实播放状态：

```json
{"success":true,"action":"play_pause","state":{"hasPlayer":true,"playing":false,"position":42,"duration":600,"volume":0.8}}
```

### 支持的 action

- 播放：`play_pause`、`play`、`pause`、`seek_forward`、`seek_backward`、
  `volume_up`、`volume_down`、`mute`
- 导航：`up`、`down`、`left`、`right`、`ok` / `select`
- 应用：`back`、`home`、`search`

## 实现要点

- `lib/services/tv_remote_server.dart` — HTTP 服务、鉴权、网页 UI
- `lib/services/tv_remote_bridge.dart` — **动作执行器**

`TVRemoteBridge` 是关键：此前 `controlStream` 没有任何订阅者，网页拿到
`{"success": true}` 但电视上什么都不会发生。现在由 Bridge 订阅并执行。

方向键与 OK 不另写一套导航逻辑，而是转成 `DirectionalFocusIntent` /
`ActivateIntent` 交给 Flutter 焦点系统，与物理遥控器完全同一条路径，
行为保持一致。

## 已知限制

- 扫码登录尚未实现（原先的占位实现只返回硬编码 URL，已从界面移除，
  避免给出「能用」的错误暗示）；需要账号登录请在电视端完成。
- `/api/settings` 目前需由宿主注入 provider 才有实际内容，默认返回空对象。

## 测试

`test/tv_remote_e2e_test.dart` 针对真实服务器做端到端验证（13 项）：
配对码格式与轮换、未授权/错误配对码一律 401 且不泄漏动作到执行流、
正确配对码可执行并回传真实状态、空 action 400、未知路径 404、无通配 CORS。

```bash
flutter test test/tv_remote_e2e_test.dart
```
