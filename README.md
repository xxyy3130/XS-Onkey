# XS-Onkey

xray/sing-box 一键快速安装脚本

## 快速安装

```
wget -O install.sh "https://raw.githubusercontent.com/xxyy3130/XS-Onkey/main/install.sh" && chmod +x install.sh && ./install.sh
```

## 协议矩阵

### VLESS / Xray

| 配置档 | 实现 |
|---|---|
| `vless-reality-vision` | VLESS + REALITY + Vision + RAW |
| `vless-xhttp-reality-enc` | VLESS Encryption + XHTTP + REALITY |
| `vless-xhttp` | VLESS Encryption + XHTTP，无 TLS |
| `vless-tcp-tls` | VLESS + Vision + RAW/TCP + TLS |
| `vless-xhttp-tls` | VLESS + XHTTP + TLS |

### 其他协议

| 配置档 | 核心/实现 |
|---|---|
| `hy2` | Xray / Hysteria2 |
| `tuic` | sing-box / TUIC v5 |
| `anytls` | sing-box / AnyTLS |
| `any-reality` | sing-box / AnyTLS + REALITY |
| `ss2022` | sing-box / `2022-blake3-aes-128-gcm` |
| `trojan` | Xray / Trojan + TLS |
| `socks` | Xray / SOCKS5，强制随机用户名和密码 |

别名：`vless`、`xray`、`sing`、`all`。

`any-reality` 是本脚本为 AnyTLS + REALITY 定义的配置档，不是独立的协议名称。分享链接仍使用 `anytls://`；部分客户端尚未识别其中的 REALITY 参数，遇到导入失败时需要使用支持该组合的 sing-box 客户端手动配置。

## 文件位置

- `/etc/xs-onekey/config.env`：协议选择、端口和凭据，权限 0600。
- `/etc/xs-onekey/xray.json`：需要 Xray 时创建。
- `/etc/xs-onekey/sing-box.json`：需要 sing-box 时创建。
- `/etc/xs-onekey/share.txt`：逐行分享链接。
- `/etc/xs-onekey/subscription.txt`：Base64 聚合订阅内容。
- `/etc/xs-onekey/tls/`：自签名或 ACME 证书。

## 安全与兼容性

- 自签名模式会为 Xray 节点附加证书指纹，并为支持该参数的 sing-box 节点启用不安全证书选项；不同客户端的分享链接兼容性不完全一致，建议生产环境使用正确解析的域名和 ACME。
- SOCKS5 即使带鉴权也容易被扫描，建议在云安全组限制来源 IP。
- 脚本阻止 sing-box 入站访问私网/保留地址，并拦截可识别的 BitTorrent 流量；这不是完整的滥用防护。
- XHTTP、VLESS Encryption、AnyTLS、AnyTLS+REALITY 等较新功能要求客户端核心足够新；旧客户端可能无法导入或连接。
- 仅在你有权管理的服务器上使用，并遵守当地法律和服务商条款。
