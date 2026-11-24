```bash
bash <(curl -fsSL https://raw.githubusercontent.com/404-git-404/404-vps-tools/main/debian-init.sh)
```

```sh
wget -qO alpine-init.sh https://raw.githubusercontent.com/404-git-404/404-vps-tools/main/alpine-init.sh && sh alpine-init.sh
```

```sh
curl -fsSL https://raw.githubusercontent.com/404-git-404/404-vps-tools/main/gg-status -o gg-status && chmod +x gg-status && ./gg-status
```

第一条命令以 root 在 Debian 12/13（amd64/arm64、systemd）运行，进入快速安装、自定义安装、退出及 SmartDNS、sing-box、Fail2ban、清理和更新菜单。本地运行 `bash debian-init.sh`。

快速安装选择 SSH 单端口和网络策略，直接回车默认使用 53651 与 Auto。`--ssh-port PORT` 和 `--network-stack auto|ipv4|dual` 分别跳过对应菜单。使用 `--ssh-port PORT --keep-22` 可兼容旧部署的备用 22。

SSH 菜单选项 4（或 `--preserve-ssh`）保留原有 SSH 监听配置、认证、公钥、服务及 UFW 规则。可独立选择 Auto、Dual-Stack 或 IPv4-only，当前 SSH 会话使用 IPv6 时禁止关闭 IPv6。切换端口前会显示现有分端口监听并要求确认，切换失败会恢复 SSH 与 UFW。

快速安装和自定义安装均可在 SSH 公钥提示直接回车。脚本检查 `/root/.ssh/authorized_keys`，显示有效公钥数量和指纹，确认后原样复用。也可直接粘贴新公钥，或使用 `--pubkey`、`--pubkey-file` 跳过询问。新公钥通过验证后去重追加。

初始化开始前收集 SSH、网络、公钥、监听风险与 Swap 选择，显示摘要并一次确认，之后自动执行。缺少公钥验证工具时仅提前安装 openssh-client。自定义安装提前选择完成基础工具后退出或继续。正式执行仍重新检查端口、公钥、监听和 Swap 状态；状态变化时安全停止或跳过 Swap。

Auto 探测当前 IPv6 连通性，只得出 IPv4 或 Dual，永远不主动禁用 IPv6，保留服务商的 IPv6 配置与 SmartDNS 的 AAAA 应答，并备份迁移本脚本旧版 IPv6 禁用策略。确认前还会扫描 `/etc/sysctl.conf` 与 `sysctl.d` 目录中非脚本管理、重启后仍会关闭 IPv6 的 `disable_ipv6 = 1`，列出文件和行：选 1 备份整个文件后仅注释对应行并按 Dual 处理（`/usr/lib`、`/usr/local/lib`、`/run` 下的文件不改原件，改在 `/etc/sysctl.d` 写同名副本并注释，包升级不会覆盖），选 2 保留并按 IPv4 处理。无交互终端或指定 `--network-stack` 时默认选 2 并警告。显式 IPv4-only 才持久关闭 IPv6，Dual-Stack 则显式启用。SmartDNS 只监听 `127.0.0.1:53`（UDP+TCP），不依赖 `::1`，重跑时清除旧的 IPv6 监听。`/etc/resolv.conf` 写入 `127.0.0.1` 与备用 `1.1.1.1`，SmartDNS 异常时系统仍可解析；SmartDNS 健康检查始终直连 `127.0.0.1`。

Dual-Stack（含 Auto 检测为双栈）补充通用 IPv4 UFW 规则的 IPv6 对应项，保留动作、方向、TCP/UDP、端口范围及注释；跳过已有项，保留冲突的 IPv6 策略并警告。地址/CIDR、源端口、接口、应用、路由和 LIMIT 等复杂规则跳过并记录原因。IPv4-only 先加载并精准清理 IPv6 规则，再设 `IPV6=no` 并 reload；Auto 探测失败保留现有 IPv6 规则及开关。保留 SSH 模式不修改 UFW。

IPv4-only 在网络服务启动后逐接口关闭 IPv6。systemd 定时器启用 1 秒后进入首次检查的调度窗口，后续每小时校正热插拔或网络重配造成的变化，调度窗口为 1 分钟。旧版用户可重跑快速安装并选择 IPv4-only，当场更新定时器。ifupdown 配置静态 IPv6 或 DHCPv6 时可短暂启用 IPv6。切回 Auto 或 Dual-Stack 会移除脚本的 IPv4-only 策略并恢复 IPv6 内核能力。静态地址和 DHCPv6 可在网络服务下次初始化或计划重启后恢复，本脚本不重启网络服务。

Debian 初始化要求根分区至少有 2048MiB 可用空间。低内存且已启用 Swap 不足 512MiB 时，脚本按 RAM 和磁盘空间推荐 2048、1024 或 512MiB，创建后至少保留 1024MiB。确认后空间减少时会降档或跳过。符合容量的旧 Swap 文件可在确认后直接复用。

选项 7（或 `--cleanup-only`）可在低于 2048MiB 时清理 APT 下载缓存、归档 Journal 和系统定义的过期临时文件。无用软件包和旧内核分别预览、分别确认，默认跳过。仅删除可安全确认的包，保留当前、默认和备用内核以及已有 Swap；报告按根分区的实际可用空间计算。

选项 1、2 默认执行 `apt update` 和 `apt full-upgrade -y`，不再单独询问升级。选项 8（或 `bash debian-init.sh --update-only`）仅执行系统更新并报告重启提示，不安装初始化工具或修改组件配置。升级时临时保护已安装的 sing-box、SmartDNS，成功、失败或中断均恢复临时 hold，保留用户原有永久 hold。`--skip-upgrade` 跳过 full-upgrade；`--full-upgrade` 和 `--base-only` 保持可用。

Debian 完整初始化包含系统更新、SSH 公钥与端口、UFW、SmartDNS、sing-box 安装及基础调优；sing-box 节点通过选项 5 单独配置，预览并确认后才应用和启动。选项 4 仅处理 SmartDNS 与系统 DNS。覆盖已有配置前备份，失败时查看输出中的备份路径。修改 SSH 后保持当前会话，并从另一终端验证新端口。

第二条命令以 root 在 Alpine/OpenRC 环境下载并运行独立初始化脚本，暂不融合 Debian 菜单。本地运行 `sh alpine-init.sh`。

第三条命令运行 Google/Gemini 可用性检测。
