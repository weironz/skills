# 仓库约定（写给 agent 和我自己）

## 分组

Skill 放在 `skills/<分组>/<skill-name>/` 下：

- `infra/`：GPU 集群、网络、存储、运维排障。主推分组。
- `productivity/`：通用工作流。主推分组。
- `in-progress/`：试验中。`link-skills.sh` 会把它链接到本机，但不进插件清单，也不进顶层 README。
- `deprecated/`：已弃用。不链接、不发布，只在自己分组的 README 里保留记录。

主推分组（`infra/`、`productivity/`）里的每个 skill，都要同时出现在以下三处：

1. 顶层 `README.md` 对应分组下的条目，skill 名链接到它的 `SKILL.md`。
2. 所属分组的 `README.md`，写一行简介。
3. `.claude-plugin/plugin.json` 的 `skills` 数组。

非主推分组的 skill 不能出现在上面第 1、3 处。新增、改名、移动或删除 skill 之后，要同步这三处，并重新运行 `scripts/link-skills.sh`。

## 编写 SKILL.md

- frontmatter 只写 `name`（与目录名一致，小写加连字符）和 `description`。description 写清楚做什么、在什么场景下触发，可以写得积极一点，否则模型容易不调用。description 里有冒号时，用 `description: >-` 块标量，避免 YAML 解析出错。
- 正文要讲清楚原因，而不只是罗列命令。尽量少用全大写的 MUST/NEVER。正文控制在 500 行以内，细节放进 `references/`，并在正文里写明什么时候去读。
- 会重复使用的采集或分析逻辑写成 `scripts/` 里的脚本。排障类脚本默认只读，凡是有副作用的操作，都要在文档里标明"需要用户同意"。
- 测试用例放在 `evals/<case>/` 下（`prompt.md`、`case.yaml`、`graders/`、`files/`），格式和 `claude plugin eval` 一致。

## 公开仓库的安全要求

这是公开仓库。提交前必须运行 `scripts/check-secrets.sh`，并且确保不包含以下内容：

- 真实的内网 IP、内部域名、主机名与机房的对应关系、BMC 或交换机地址。
- 任何 token、密码、私钥、License Key，以及内部镜像仓库地址。
- 客户名、同事姓名、真实容器名或 ID、真实 boot ID。

来自真实故障的案例要先脱敏：用泛称代替具体节点名，数值和日志形态可以保留，测试用例里使用虚构的主机名。

## 校验

修改插件清单后运行：

```bash
claude plugin validate .   # 加 --strict 时，根目录 CLAUDE.md 和缺少图标会报警告，可以忽略
```
