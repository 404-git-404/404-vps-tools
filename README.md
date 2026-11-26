```bash
bash <(curl -fsSL https://raw.githubusercontent.com/404-git-404/404-vps-tools/main/debian-init.sh)
```

```sh
wget -qO alpine-init.sh https://raw.githubusercontent.com/404-git-404/404-vps-tools/main/alpine-init.sh && sh alpine-init.sh
```

```sh
curl -fsSL https://raw.githubusercontent.com/404-git-404/404-vps-tools/main/gg-status -o gg-status && chmod +x gg-status && ./gg-status
```

第一条命令以 root 在 Debian 12/13（amd64/arm64、systemd）运行，菜单：1 快速初始化、2 自定义初始化、3 SmartDNS、4 安装/升级 sing-box、5 Fail2ban、6 系统更新、7 清理、8 安全加固、0 退出；9 预留。本地运行 `bash debian-init.sh`。

快速安装选择 SSH 单端口和网络策略，直接回车默认使用 53651 与 Auto。`--ssh-port PORT` 和 `--network-stack auto|ipv4|dual` 分别跳过对应菜单。使用 `--ssh-port PORT --keep-22` 可兼容旧部署的备用 22。

SSH 菜单选项 4（或 `--preserve-ssh`）保留原有 SSH 监听配置、认证、公钥、服务及 UFW 规则。可独立选择 Auto、Dual-Stack 或 IPv4-only，当前 SSH 会话使用 IPv6 时禁止关闭 IPv6。切换端口前会显示现有分端口监听并要求确认，切换失败会恢复 SSH 与 UFW。

快速安装和自定义安装均可在 SSH 公钥提示直接回车。脚本检查 `/root/.ssh/authorized_keys`，显示有效公钥数量和指纹，确认后原样复用。也可直接粘贴新公钥，或使用 `--pubkey`、`--pubkey-file` 跳过询问。新公钥通过验证后去重追加。

初始化开始前收集 SSH、网络、公钥、监听风险与 Swap 选择，显示摘要并一次确认（回车默认 Y），之后自动执行。缺少公钥验证工具时仅提前安装 openssh-client。自定义安装提前选择完成基础工具后退出或继续。正式执行仍重新检查端口、公钥、监听和 Swap 状态；状态变化时安全停止或跳过 Swap。

Auto 探测当前 IPv6 连通性，只得出 IPv4 或 Dual，永远不主动禁用 IPv6，保留服务商的 IPv6 配置与 SmartDNS 的 AAAA 应答，并备份迁移本脚本旧版 IPv6 禁用策略。确认前用 `systemd-sysctl` 在临时网络命名空间里计算重启后 `all`/`default` 的 `disable_ipv6`，宿主机不受影响。被关闭时列出相关文件和行：选 1 写入脚本自己的 `/etc/sysctl.d/99-vps-init-network.conf` 覆盖并再次验证，不修改任何原有文件；仍被更靠后的配置关闭则撤销（原本存在的覆盖文件恢复原样）并按 IPv4 处理；无法验证时报告“已写入、未验证”，不当作已恢复。选 2 保留并按 IPv4 处理。无交互终端或指定 `--network-stack` 时默认选 2 并警告；缺少 `unshare`/`systemd-sysctl` 或运行受限时无法判断，只警告。已知限制：具体网卡名的 `disable_ipv6` 无法判断。报告分别显示“重启后 IPv6”和“当前探测”。显式 IPv4-only 才持久关闭 IPv6，Dual-Stack 则显式启用。SmartDNS 只监听 `127.0.0.1:53`（UDP+TCP），不依赖 `::1`，重跑时清除旧的 IPv6 监听。`/etc/resolv.conf` 写入 `127.0.0.1` 与备用 `1.1.1.1`，SmartDNS 异常时系统仍可解析；SmartDNS 健康检查始终直连 `127.0.0.1`。联网前先检查系统 DNS：不可用但 IPv4 直连正常时，备份 `/etc/resolv.conf` 后提前写入同样的三行（询问默认 Y，无交互终端自动执行），此修复不随后续失败回滚；直连也不通则报告“IPv4 网络不可用”并中止。

Dual-Stack（含 Auto 检测为双栈）补充通用 IPv4 UFW 规则的 IPv6 对应项，保留动作、方向、TCP/UDP、端口范围及注释；跳过已有项，保留冲突的 IPv6 策略并警告。地址/CIDR、源端口、接口、应用、路由和 LIMIT 等复杂规则跳过并记录原因。IPv4-only 先加载并精准清理 IPv6 规则，再设 `IPV6=no` 并 reload；Auto 探测失败保留现有 IPv6 规则及开关。保留 SSH 模式不修改 UFW。

IPv4-only 在网络服务启动后逐接口关闭 IPv6。systemd 定时器启用 1 秒后进入首次检查的调度窗口，后续每小时校正热插拔或网络重配造成的变化，调度窗口为 1 分钟。旧版用户可重跑快速安装并选择 IPv4-only，当场更新定时器。ifupdown 配置静态 IPv6 或 DHCPv6 时可短暂启用 IPv6。切回 Auto 或 Dual-Stack 会移除脚本的 IPv4-only 策略并恢复 IPv6 内核能力。静态地址和 DHCPv6 可在网络服务下次初始化或计划重启后恢复，本脚本不重启网络服务。

Debian 初始化要求根分区至少有 2048MiB 可用空间。低内存且已启用 Swap 不足 512MiB 时，脚本按 RAM 和磁盘空间推荐 2048、1024 或 512MiB，创建后至少保留 1024MiB。确认后空间减少时会降档或跳过。符合容量的旧 Swap 文件可在确认后直接复用。

完整快速/自定义初始化成功后自动清理 APT 缓存、归档 Journal 和过期临时文件，失败只警告；`--base-only` 跳过。重启后可运行选项 7 清理旧内核和无用包。

选项 7（或 `--cleanup-only`）可在低于 2048MiB 时清理 APT 下载缓存、归档 Journal 和系统定义的过期临时文件。无用软件包和旧内核分别预览、分别确认，默认跳过。仅删除可安全确认的包，保留当前、默认和备用内核以及已有 Swap；报告按根分区的实际可用空间计算。

选项 1、2 默认执行 `apt update` 和 `apt full-upgrade -y`，不再单独询问升级。选项 6（或 `bash debian-init.sh --update-only`）仅执行系统更新并报告重启提示，不安装初始化工具或修改组件配置。升级时临时保护已安装的 sing-box、SmartDNS，成功、失败或中断均恢复临时 hold，保留用户原有永久 hold。`--skip-upgrade` 跳过 full-upgrade；`--full-upgrade` 和 `--base-only` 保持可用。

Debian 完整初始化包含系统更新、SSH 公钥与端口、UFW、SmartDNS、sing-box 安装及基础调优，不创建节点配置。选项 3 仅处理 SmartDNS 与系统 DNS。旧版遗留的 `/var/lib/404-vps-tools/network-stack` 在快速/自定义初始化和选项 4 运行时删除。覆盖已有配置前备份，失败时查看输出中的备份路径。修改 SSH 后保持当前会话，并从另一终端验证新端口。

第二条命令以 root 在 Alpine/OpenRC 环境下载并运行独立初始化脚本，暂不融合 Debian 菜单。本地运行 `sh alpine-init.sh`。

第三条命令运行 Google/Gemini 可用性检测。

快速初始化默认开启 Debian 安全源自动更新，自定义初始化可选（默认开启）；不自动重启、不发邮件，保留 hold，排除 sing-box/SmartDNS。初始化只为 sing-box 设置开机自启，不启动；启动条件先写好，没有 /etc/sing-box/config.json 时开机跳过。结尾检查各服务自启与 UFW 实际状态，缺少自启则 enable，不额外启动；保留 SSH 模式下 ssh、ufw、fail2ban 只报告。

选项 8 先只读体检并分三级显示（A 建议删除、B 需要你看一眼、C 严重异常），A 级有项时先显示风险提示并确认，再逐项确认（默认 N），先备份后执行，结尾给出报告和恢复方式；没有 A 级项时不创建备份。QEMU Guest Agent 只在这里卸载，初始化不再涉及。初始化把用户提供或确认复用的公钥指纹保存在 /var/lib/404-vps-tools/trusted-key-fingerprints；无法确定当前 SSH 会话所用公钥、公钥只剩一把、当前会话公钥，均禁止删除。商家 agent 按进程名、服务名或安装路径识别，仅软件包安装且不在 Debian 官方源的才可 purge，其余只报告并提示手动卸载。exim4 可选卸载，先模拟 `apt-get -s purge 'exim4*'`，连带删除非 exim4 包时列出名单并额外确认，卸载后 cron 邮件将无法投递。

运行 `bash debian-init.sh --audit` 只读体检，完整报告输出到终端，不创建备份、锁或临时文件。cloud-init 仅在网络配置已写在 /etc 的普通文件（ifupdown、netplan、systemd-networkd，DHCP 或静态均可）且未配置每次开机重新生成网络时才可关闭；否则只跳过这一项。关闭方式是创建 /etc/cloud/cloud-init.disabled，恢复时删除该文件。

选项 4（或 `--sing-box-only`，可加 `--sing-box-version VER`）安装或升级 sing-box，不需要交互终端，sing-box 只通过选项 4 升级。流程：配置 SagerNet 软件源（固定密钥指纹）并 `apt update`，记录当前版本、运行状态、`/etc/sing-box/config.json` 是否存在和永久 hold，然后安装稳定版或升级到仓库最新稳定版。安装/升级期间临时写入 `/usr/sbin/policy-rc.d`（exit 101）阻止软件包自动重启服务，结束或中断后还原原有文件。已被 `apt-mark hold` 的 sing-box 跳过升级。有配置时，按 `sing-box.service` 实际的 ExecStart（`-c` 或 `-C` 及路径）运行 `sing-box check`：通过且服务原本在运行才重启，等待 5 秒确认 active，没有变成 active 则降级回原版本并重新启动；检查不通过则降级回原版本，原进程不动；仓库里找不到原版本无法降级时显示警告，不重启服务。首次安装或没有配置不检查、不启动。最后设为开机自启（没有配置文件时开机跳过），输出版本变化、hold、检查、重启、降级及服务状态报告。
