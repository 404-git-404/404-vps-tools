# Project rules

- 项目只面向 Debian 12/13，支持 Debian 默认 Bash 环境。
- 用户入口主脚本固定为 `404notfound.sh`，不得保留旧名称的兼容副本或软链接。
- Shell 脚本必须使用 `set -Eeuo pipefail`。
- 根目录 `yt-region` 是唯一例外：它是独立 POSIX sh 工具，必须保持 `#!/bin/sh` 和 `set -eu`，不要求 `set -Eeuo pipefail`；此例外不得用于其他 Shell 脚本，也不得修改其已通过 Debian / Alpine 实机测试的代码。
- 所有系统修改必须可验证、尽量幂等，并在覆盖配置前创建备份。
- SSH 变更首先考虑防止用户被锁在服务器外；UFW 收紧必须晚于 SSH 全部门禁。
- 不得提交密钥、密码、Token、UUID、证书、真实域名、服务器 IP 或节点参数。
- 初始化流程允许安装但不启动 sing-box，安装、配置并启动 SmartDNS，安装 `domain-check`，以及安装 Cloudflare 8443 UFW 更新工具。
- `domain-check.sh` 是仓库根目录的独立工具，初始化流程将其安装为 `/usr/local/bin/domain-check`。
- 第一阶段不得写入 sing-box 业务 JSON，不得创建 Reality、Hysteria2 或其他代理节点，不得申请或部署证书，不得配置 Cloudflare Tunnel 或 CF-WS，也不得写入节点 UUID、密码、私钥、Token、真实域名或服务器信息。
- 修改 Shell 脚本后必须运行 `bash -n` 和 ShellCheck。
- README 内容必须严格保持三条运行命令，不得添加标题、说明、围栏或空行。
- README 唯一允许在现有内容末尾追加一个 `yt-region` 区块，且仅可包含一个 `yt-region` 标题、一行 `YouTube 地区检测` 和一个只含单条“下载 + chmod + 运行”命令的 shell 围栏代码块；此例外不得用于其他内容或工具。
- 不得无理由增加依赖，也不要过早拆分大量文件。
