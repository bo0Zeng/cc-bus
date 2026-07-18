#!/usr/bin/env bash
# cc-bus 安装脚本 —— 把脚本软链到 PATH、建运行时目录、放示例配置。
# 【只做可逆的本地安装】:不改全局 settings.json、不 systemctl。最后打印需你手动做的激活步骤。
# 可用环境变量覆盖(供测试):CCBUS_BINDIR(默 ~/.local/bin)、CC_BUS_HOME(默 ~/.cc-bus)。
set -euo pipefail
SRC=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)     # 脚本规范源目录
BINDIR="${CCBUS_BINDIR:-$HOME/.local/bin}"
BUSHOME="${CC_BUS_HOME:-$HOME/.cc-bus}"
SKILLDIR=$(dirname "$SRC")                                # skills/cc-bus

mkdir -p "$BINDIR" "$BUSHOME"/{inbox,state,log,queue}

# 软链可执行脚本(cc-bus-lib.sh 不链:各脚本用 readlink -f 定位真身目录再 source 它)
# 不静默覆盖用户已有同名命令:仅刷新指向本仓库 scripts/ 的旧软链,其余跳过并告警。
skipped=""
for s in cc-whoami cc-register cc-send cc-recv cc-list cc-broadcast cc-bus-stop-hook cc-busd cc-spawn cc-kill cc-agents; do
  chmod +x "$SRC/$s"
  dst="$BINDIR/$s"
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    cur=$(readlink -f "$dst" 2>/dev/null || true)
    case "$cur" in
      */scripts/"$s") ;;                    # 本仓库(live 或分发仓)旧软链 → 刷新
      *) skipped="$skipped $s"; continue;;  # 陌生的同名命令 → 不覆盖
    esac
  fi
  ln -sf "$SRC/$s" "$dst"
done
chmod +x "$SRC/cc-bus-lib.sh"
[ -n "$skipped" ] && echo "⚠ 跳过(PATH 已有同名命令,未覆盖):$skipped —— 确认要用本版本请先手动移除再重装"

# 放示例配置(不覆盖已有;默认不激活任何阀门/ACL)
[ -f "$BUSHOME/config.example" ]     || cp "$SKILLDIR/examples/config"     "$BUSHOME/config.example"
[ -f "$BUSHOME/policy.tsv.example" ] || cp "$SKILLDIR/examples/policy.tsv" "$BUSHOME/policy.tsv.example"

echo "✅ 已安装:11 个命令 → $BINDIR;运行时根 → $BUSHOME"
case ":$PATH:" in *":$BINDIR:"*) :;; *) echo "⚠ $BINDIR 不在 PATH,请加入";; esac

cat <<EOF

—— 剩下需你手动做的激活步骤(本脚本刻意不碰)——

1) 【收信钩子】把下面合并进 ~/.claude/settings.json 的顶层(保留你现有字段,只加 hooks):
   "hooks": {
     "SessionStart": [ { "hooks": [ { "type": "command",
        "command": "cc-register >/dev/null 2>&1 || true" } ] } ],
     "Stop": [ { "hooks": [ { "type": "command", "command": "cc-bus-stop-hook" } ] } ]
   }
   校验:jq . ~/.claude/settings.json

2) 【启动 CC】:直接在 tmux pane 里普通启动 \`claude\` 即可——身份自动 = tmux 会话名(如 shengwu_cc),
   无需 CC_BUS_ID。想给同一会话里多个 CC 细分,给各自 pane 打标签:  tmux set -p @cc_id <名字>
   (查自己是谁:cc-whoami;看谁在线:cc-list)

3) 【可选:broker 守护进程】(不装也能用——不在时 cc-send 自动兜底跑同一套管线)
   手动前台/后台:  cc-busd start   (停:cc-busd stop;状态:cc-busd status)
   或装成 systemd --user 服务(开机自启):
     mkdir -p ~/.config/systemd/user && cp "$SKILLDIR/examples/cc-busd.service" ~/.config/systemd/user/
     systemctl --user daemon-reload && systemctl --user enable --now cc-busd

4) 【可选:开路由策略】cp $BUSHOME/config.example $BUSHOME/config,按需开限流/ACL(见文件注释)。

停用:从 settings.json 删 hooks 段;cc-busd stop;删 $BINDIR 里的软链。脚本本体无害留存。
EOF
