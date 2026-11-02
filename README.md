# Skills

我个人日常使用的 AI agent skills，来自真实工作中踩过的坑和复盘。每个 skill 都尽量做到：小而专注、讲清楚背后的原因、附带可以直接运行的只读脚本，适用于 Claude Code、Codex 和其他兼容 [Agent Skills](https://agentskills.io) 的工具。

目录结构参考了 [mattpocock/skills](https://github.com/mattpocock/skills)。

## 安装

### Claude Code（插件方式，可自动更新）

```bash
claude plugin marketplace add weironz/skills
claude plugin install weironz-skills@weironz
```

### Codex 及其他工具（软链接方式，`git pull` 后即更新）

```bash
git clone https://github.com/weironz/skills.git ~/codes/skills
~/codes/skills/scripts/link-skills.sh      # 链接到 ~/.claude/skills 和 ~/.agents/skills
```

Windows 下可以手动把 `skills/<分组>/<skill>/` 目录复制到 `%USERPROFILE%\.agents\skills\`。

插件方式和软链接方式选一种就行，两种都装的话，每个 skill 会出现两份。

## Skills

### infra：GPU 集群、网络、运维排障

- [b300-cx8-troubleshooting](./skills/infra/b300-cx8-troubleshooting/SKILL.md)：排查 NVIDIA B300 服务器上 ConnectX-8 网卡的各类异常（固件挂死、驱动初始化超时、PCIe 未枚举、IB 端口 Down、topo 丢 NIC 等）。按依赖层分诊，定位 T0，追查触发源，并说明各种恢复手段的实际影响。附带只读采集脚本和测试用例。

### productivity：通用工作流

（暂无）

其他分组：[in-progress](./skills/in-progress/README.md)（试验中，不随插件发布）、[deprecated](./skills/deprecated/README.md)（已弃用）。

## 目录结构

```
skills/
├── infra/            # 主推：GPU/网络/运维排障
├── productivity/     # 主推：通用工作流
├── in-progress/      # 试验中，会被软链接到本机，但不随插件发布
└── deprecated/       # 已弃用，不链接、不发布
scripts/
├── link-skills.sh    # 把 skill 软链接到本机各 agent 的 skill 目录
├── list-skills.sh    # 列出全部 skill 及其所属分组
├── check-secrets.sh  # 扫描内网 IP、token、内部域名（--staged 只扫描暂存区）
└── install-hooks.sh  # 启用 .githooks/pre-commit（每次 clone 后运行一次）
.githooks/pre-commit  # 每次提交前自动运行 check-secrets --staged
.claude-plugin/       # Claude Code 插件清单（plugin.json / marketplace.json）
```

单个 skill 的结构：

```
<skill-name>/
├── SKILL.md          # frontmatter（name, description）和使用说明
├── references/       # 按需加载的详细文档
├── scripts/          # 可以直接运行的脚本
└── evals/            # 测试用例（claude plugin eval 格式）
```

## 参与维护

```bash
git clone https://github.com/weironz/skills.git && cd skills
scripts/install-hooks.sh     # 启用提交前的敏感信息检查
```

内部关键词（内部域名、机房代号等）可以写进 `.secrets-denylist`，每行一个正则。这个文件已加入 .gitignore，不会被提交。

## License

[MIT](./LICENSE)
