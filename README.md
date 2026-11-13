```bash
bash <(curl -fsSL https://raw.githubusercontent.com/404-git-404/404-vps-tools/main/debian-init.sh)
```

```sh
wget -qO alpine-init.sh https://raw.githubusercontent.com/404-git-404/404-vps-tools/main/alpine-init.sh && sh alpine-init.sh
```

```sh
curl -fsSL https://raw.githubusercontent.com/404-git-404/404-vps-tools/main/gg-status -o gg-status && chmod +x gg-status && ./gg-status
```

第一条命令以 root 在 Debian 12/13（amd64/arm64、systemd）运行，进入快速安装、自定义安装、退出及 SmartDNS、sing-box、Fail2ban 独立安装菜单。本地运行 `bash debian-init.sh`。

快速安装选择 SSH 单端口和网络策略，直接回车默认使用 53651 与 Auto。`--ssh-port PORT` 和 `--network-stack auto|ipv4|dual` 分别跳过对应菜单。使用 `--ssh-port PORT --keep-22` 可兼容旧部署的备用 22。

Auto 探测当前 IPv6 连通性，保留服务商的 IPv6 配置与 SmartDNS 的 AAAA 应答，并备份迁移本脚本旧版 IPv6 禁用策略。显式 IPv4-only 才持久关闭 IPv6，Dual-Stack 则显式启用。SmartDNS 始终监听 IPv4 本地端口，IPv6 回环可用时添加 IPv6 监听。

Debian 完整初始化包含系统更新、SSH 公钥与端口、UFW、SmartDNS、sing-box 安装及基础调优；sing-box 节点通过选项 5 单独配置，预览并确认后才应用和启动。选项 4 仅处理 SmartDNS 与系统 DNS。覆盖已有配置前备份，失败时查看输出中的备份路径。修改 SSH 后保持当前会话，并从另一终端验证新端口。

第二条命令以 root 在 Alpine/OpenRC 环境下载并运行独立初始化脚本，暂不融合 Debian 菜单。本地运行 `sh alpine-init.sh`。

第三条命令运行 Google/Gemini 可用性检测。
