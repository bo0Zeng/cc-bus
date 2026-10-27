# cc-bus

> **已归档。** cc-bus 已并入 [cc-monitor](https://github.com/bo0Zeng/cc-monitor)（`src/shared/cc-bus/`），依赖它的后端；这个仓库不再维护。

[English](README.md) | **中文**

多个各自独立运行在 tmux 里的 **Claude Code** 实例之间的消息总线——让分开的会话互相收发/转发/广播消息,并派生出扎根在指定目录的协作会话,自带智能路由和可选的 broker 守护进程。

Claude Code 本身没有给"已经在跑的"实例发消息的原生方式。cc-bus 补上了这个能力:消息通过 `tmux send-keys`(即"敲门")投递,落盘到每个实例专属的 inbox 文件(唯一真相源),并经过一条管线路由(ACL / 限流 / 去重 / 灭环 / 敲门去抖)。`Stop` 钩子会在会话空闲时也照常清空 inbox,所以哪怕对方正忙,消息也不会丢。

## 两个语言版本——选一个装

本仓库把**同一个插件做了两份语言版本**,各自独立成一份完整拷贝:

| 目录 | 版本 | 文档、注释与用户可见字符串 |
|-----------|---------|------------------------------------------|
| [`en/`](en/) | English | 英文 |
| [`zh/`](zh/) | 中文    | 中文 |

两者行为逐字节一致——只有自然语言文本不同。装你喜欢的那个就行,不用两个都装。

## 你能得到什么

- 运行中的会话之间**发送 / 转发 / 广播**(`cc-send`、`cc-broadcast`)。
- **被动收信**——`SessionStart` 钩子自动注册会话;`Stop` 钩子在回合结束前送达排队的消息(哪怕对方正在忙也照送)。
- 身份**从 tmux 自动获取**(会话名;可用 `@cc_id` pane option 或 `$CC_BUS_ID` 覆盖)。不用手工分配 ID。
- **智能路由**,默认**全部关闭**(表现如同一条裸总线):按对/全局限流、ACL / 星形拓扑、去重、灭环、敲门去抖。
- **可选的 broker 守护进程** `cc-busd`,做集中式异步投递;不装它的话,`cc-send` 就地跑**同一套**路由管线,消息不会被丢弃。
- **派生协作者**——`cc-spawn <目录> [任务]` 打开一个独立的、扎根在某目录的 Claude Code 会话(历史隔离、原生文件访问),自动加入总线。`cc-kill` / `cc-agents` 管理它们的生命周期。区别于 subagent:这是一个真实的、长驻的、独立上下文的进程。

## 环境要求

- **Linux**(用到 `flock`、`pgrep`、`/proc`)、**bash 4+**、**tmux**。
- **`jq`**(信封的组装/解析)与 util-linux 的 **`flock`**(并发安全)——两者都必需。
- 支持插件的 **Claude Code**(或参见下文手动安装)。

## 安装

以下都以英文版(`en/`)为例;要装中文版,把 `en/` 换成 `zh/` 即可。

### 作为 Claude Code 插件

```bash
/plugin install cc-bus      # 从某个 marketplace 安装,或把本仓库(en/ 或 zh/ 子目录)加为插件源
```

安装插件会自动激活 **hooks** 与 **skill**。但 Claude Code 的插件系统**不会**把 `cc-*` 脚本放上你的 shell `PATH`——被动收信立即可用,而**主动发信 / 广播 / 派生需要命令在 `PATH` 上**,所以要再跑一次安装器:

```bash
bash en/install.sh   # 把 11 个 cc-* 命令软链到 ~/.local/bin,并创建 ~/.cc-bus/
```

确认 `~/.local/bin` 在你的 `PATH` 里(大多数发行版默认会加)。安装器不会覆盖已存在的同名命令——遇到会跳过并提示警告。

### 手动安装(不走插件系统)

```bash
git clone https://github.com/bo0Zeng/cc-bus && cd cc-bus
bash en/install.sh
```

然后把两个 hooks 加进 `~/.claude/settings.json`(格式参见 [`en/hooks/hooks.json`](en/hooks/hooks.json)),指向安装好的 `cc-register` / `cc-bus-stop-hook`。安装器会打印出确切的激活步骤。

## 工作原理

**投递靠敲门,送达靠钩子,去重靠 offset,路由靠管线,承载靠 broker + 兜底,拓扑靠策略。**

- **唯一真相源:** `~/.cc-bus/inbox/<id>.jsonl`——每条消息是一个追加写入的信封,按字节 offset 消费(所以重投与去重都是精确的)。
- **信封(v2):** `{id, from, to, ts, text, class, in_reply_to, trace, hops, prio}`。
- **管线**(唯一实现在 `scripts/cc-bus-lib.sh`,daemon 与就地兜底共用):ACL → 限流/熔断 → 灭环 → 去重 → 写入 inbox → 敲门去抖。

所有运行时数据都存在 `~/.cc-bus/` 下(按用户、单机):`inbox/*.jsonl`、`state/*`(offset / 因果游标 / 去抖状态)、`agents.tsv`(名册)、`queue/`、`log/`、`config`、`policy.tsv`。**这些都不在本仓库里**——仓库里只有代码。

## 使用方式

cc-bus 由一个**面向 agent 的 skill** 驱动(每个版本各自的 `skills/cc-bus/SKILL.md`)——运行中的 Claude Code 实例会读它,并在你用自然语言让它联系/通知/广播给另一个会话、或在某目录派生一个会话时,自己去调用 `cc-*` 命令。你不需要亲手敲这些命令。

这个 skill 还带一套**通信纪律**(先核实再回答;转述时带原文和出处;抗迎合、不互相盖章;标注可信度与意图),防止信息在 agent 之间传递时失真走样。

## 路由(可选)

全部默认关闭。在 `~/.cc-bus/config`(可被 source 的 `KEY=VAL`)与 `~/.cc-bus/policy.tsv`(ACL)里配置;示例见各版本的 `examples/`。改动即时生效(热加载)。常用开关:`CCBUS_RATE_PAIR` / `CCBUS_RATE_GLOBAL`(反 storm)、`CCBUS_POLICY_MODE=on` + `policy.tsv`(星形拓扑)、`CCBUS_DEDUP_WINDOW`、`CCBUS_TTL`。

## broker 守护进程(可选)

```bash
cc-busd start | stop | status
```

或把它装成 `systemd --user` 服务——见各版本的 `examples/cc-busd.service`。不装守护进程时,`cc-send` 会退回到就地跑同一套管线(注意:纯兜底部署没有崩溃恢复的 reaper——需要这个特性就把 `cc-busd` 跑起来)。

## 卸载

从 `settings.json` 里移除两个 hooks(或卸载插件)、跑 `cc-busd stop`、删掉 `~/.local/bin` 里的 `cc-*` 软链。运行时数据会留在 `~/.cc-bus/` 下,直到你自己删除。

## 开发

两个版本行为完全一致——只有自然语言文本(注释、文档、用户可见字符串)不同。改代码时,把同样的改动应用到 **`en/` 和 `zh/` 两边**;改文档/注释/字符串时,保持两个版本同步。`en/` 版本是 `zh/` 版本的翻译。

## License

[MIT](LICENSE)。
