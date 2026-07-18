#!/usr/bin/env bash
# 本地安装(非 plugin 方式):软链 cc-* 命令到 PATH + 建运行时目录 + 打印激活步骤。
# 若通过 Claude Code plugin 系统安装本仓库,skill 与 hooks 会被自动接管(见 README);
# 但 cc-* 命令要能被 agent 当裸命令跑,仍需这一步把它们软链上 PATH。
set -euo pipefail
REPO=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
exec bash "$REPO/scripts/cc-bus-install.sh" "$@"
