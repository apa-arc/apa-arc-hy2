# apa-arc-hy2

交互式 HY2（Hysteria 2）一键安装脚本，使用 sing-box 作为服务端核心。

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/apa-arc/apa-arc-hy2/main/install.sh)
```

每次运行都会先从 GitHub `main` 分支获取最新 `install.sh`，通过 Bash 语法检查后再执行；获取失败或检查不通过时会停止，不会悄悄运行旧脚本。安装命令长期固定不变。

## 当前脚本功能

- 自动识别 Debian、Ubuntu、Alpine、RHEL/CentOS/Rocky/AlmaLinux/Fedora 系统及 CPU 架构
- 自动检测公网 IPv4 / IPv6，并由用户选择可用的 IP 类型
- 安装时只需输入一个起始端口：HY2 使用起始端口，VLESS Reality 自动递进 +10，Trojan TLS 自动递进 +20；校验端口范围并检查冲突
- 支持域名 Let's Encrypt 证书（HTTP-01，需要 TCP 80 可访问）或自动生成带 IP SAN 的自签名证书
- 自动获取并安装 sing-box 最新正式版
- 部署三种协议：Hysteria 2 + Salamander、VLESS Reality、Trojan TLS
- VLESS Reality 自动生成密钥、UUID 和 short ID；Trojan 复用所选 TLS 证书
- 分别输出三种协议的分享链接，并合并为 all-nodes.txt 节点集合
- 输出 sing-box 客户端 JSON 和 Clash Meta YAML，均只包含上述三种协议
- 在内核支持时启用 BBR，并设置 FQ 与基础 UDP 缓冲区参数
- systemd 系统每周检查 sing-box 更新；更新前备份二进制，配置校验失败或服务启动失败时回滚
- 安装完成后保留配置、端口、密码和证书；更新只替换 sing-box 程序，不重写服务端配置

## 导出文件

安装后生成在服务器 `/root/sing-box/`：

- `all-nodes.txt`：三种协议的完整节点链接集合
- `subscription.txt`：Base64 编码订阅内容
- `hy2.txt`：HY2 节点 URI
- `vless-reality.txt`：VLESS Reality 节点 URI
- `trojan.txt`：Trojan TLS 节点 URI
- `sing-box-client.json`：sing-box 客户端配置
- `clash-meta.yaml`：Clash Meta 节点配置

## 管理

```bash
systemctl status sing-box
/usr/local/sbin/sing-box-update
```

Alpine/OpenRC 系统使用：

```bash
rc-service sing-box status
```

## 重要说明

- 域名证书申请使用 ACME standalone HTTP-01，域名必须解析到本机，且 TCP 80 端口申请时可用。
- IP 证书为自签名证书，客户端配置会启用跳过证书验证；请妥善保护节点 URI 和密码。
- 脚本不会强制更换内核。BBR 不受当前内核支持时会提示，不会盲目升级内核。
- Shadowsocks 2022 已从服务端协议和客户端配置/节点导出中移除。
- JD 专项加速模块尚未纳入：目前没有可核验的 JD 脚本原文/下载地址，不会擅自执行来源不明的远程脚本。
