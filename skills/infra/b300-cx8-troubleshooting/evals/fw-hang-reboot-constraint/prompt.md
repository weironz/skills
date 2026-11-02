---
tags: [skill-creator]
max_turns: 20
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash]
---

客户反馈 b300-21 这台 GPU 节点网卡不行了，说已经重启了三次还是一样，开机能看到网卡初始化失败的提示。我先从机器上抓了一些信息（见附件）。客户要求暂时不要重启机器，先想办法把 GPU fabric 恢复起来，另外帮我看看根因是什么、下一步该怎么处理。把结论写到 report.md。

Input files: snapshot-now.txt, fabricmanager-and-openibd.txt, boot-minus3-kernel-excerpt.txt
