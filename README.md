# PUC Toolkit 技能包

`puc-toolkit` 是一组面向 PUC 环境日常配置、运维和发布工作的 Codex 技能包。目前仓库包含 4 个技能包，分别用于 PUC 配置管理、业务日志采集、语言资源刷新和前端制品部署。

## 技能包一览

| 技能包 | 主要用途 | 典型场景 |
|---|---|---|
| [`puc-config`](./puc-config/) | 通过 PUC 配置接口管理环境、账号、人员、配置和平台功能 | 初始化环境、登录认证、批量创建或修改账号、导入导出配置与 License |
| [`get-business-log`](./get-business-log/) | 从日志服务环境按账号和时间范围采集业务日志 | 问题排查、业务链路分析、导出指定环境的匹配日志 |
| [`refresh-puc-language`](./refresh-puc-language/) | 刷新 Kubernetes 环境中的 PUC 语言资源 | 清理 `nmnginx` 的 locale 目录并重建 Pod，使词条更新生效 |
| [`replace-env-dist`](./replace-env-dist/) | 将本地前端 `dist` 发布到目标 PUC 环境 | 构建前端项目、上传制品、发现或补充服务、替换容器静态资源 |

## 创建桌面入口

Windows 用户可以在仓库根目录执行以下命令，创建或刷新 PUC 配置工具的桌面入口：

```cmd
puc-config\scripts\Invoke-PucScript.cmd Install-PucConfigToolShortcut.ps1
```

命令会在当前用户桌面创建 `PUC Toolkit.lnk`。如果仓库或技能包路径发生变化，再次执行同一命令即可刷新快捷方式。双击桌面的 `PUC Toolkit`，即可在不显示 PowerShell 或命令提示符窗口的情况下打开图形化配置工具。

## 技能包简介

### puc-config

`puc-config` 是 PUC 配置管理的统一入口，通过配置接口对指定环境执行认证和管理操作。

主要能力：

- 初始化或更新环境连接信息，校验并复用已保存的 Token，失效后通过本地验证码窗口重新登录。
- 批量创建调度账号和通讯录人员，查询或更新账号信息，重置单个或多个账号的密码。
- 预检并新增固定警情等级，遇到代码或名称冲突时跳过冲突项。
- 导入或导出 PUC 配置与 License，并输出文件大小和 SHA-256 供核验。
- 导入 `WebPUC`、`APP` 或 `WebConfs` 权限菜单。
- 查询和配置重复账号登录时强制退出旧会话的功能开关。
- 在批量写入前执行认证预检，写入失败或结果不确定时停止，避免重复创建或错误覆盖。

入口文档：[`puc-config/SKILL.md`](./puc-config/SKILL.md)

### get-business-log

`get-business-log` 用于从独立的日志服务环境中读取和收集业务日志。它会区分目标业务环境、实际登录的日志服务环境，以及 `/opt/logserver/log` 下的环境目录，避免把三者错误地视为同一个地址或名称。

主要能力：

- 按账号字符串和精确时间范围扫描 `/opt/logserver/log/<日志目录>/business_0`。
- 支持普通文本日志，以及按需扫描 `.gz`、`.zst` 等压缩历史日志。
- 通过 SSH 自动执行远程采集、下载结果并清理临时归档；也支持在 FinalShell 中手动执行。
- 默认将结果保存到桌面的 `<日志目录>_业务日志` 文件夹。
- 输出匹配日志、摘要、清单和已扫描文件列表，便于问题定位和留档。
- 全程只读远程日志，不删除、截断、轮转或修改日志文件。

入口文档：[`get-business-log/SKILL.md`](./get-business-log/SKILL.md)

### refresh-puc-language

`refresh-puc-language` 用于刷新 PUC Kubernetes 环境中的语言资源。它会定位 `nmnginx` Pod 及其 locale 目录，清理旧语言资源后删除 Pod，由 Kubernetes 自动重建并加载最新词条。

主要能力：

- 通过 SSH、FinalShell 或当前远程终端连接目标环境。
- 自动检查命名空间，定位运行中的 `nmnginx-*` Pod。
- 从 Pod 描述信息中发现 locale 目录，并校验路径是否满足安全条件。
- 先执行 dry run，展示命名空间、Pod、locale 路径和待执行命令，再进行实际操作。
- 支持为指定环境记住“预检成功后不再重复确认”的偏好。
- 清理 locale 目录并重启对应 Pod，使语言资源重新生成。

该技能包含删除远程目录和重启 Pod 的操作，必须以预检结果为依据，不能猜测命名空间、Pod 或 locale 路径。

入口文档：[`refresh-puc-language/SKILL.md`](./refresh-puc-language/SKILL.md)

### replace-env-dist

`replace-env-dist` 用于将本地前端构建产物发布到 PUC 环境。它可以直接使用已有的 `dist`，也可以先在指定项目目录执行构建命令，再通过 SSH 或 FinalShell 上传并替换容器中的静态资源。

主要能力：

- 校验本地 `dist`，或在指定项目目录中执行用户明确提供的构建命令。
- 将制品上传到目标环境 `/home/<指定目录>/dist`。
- 自动发现命名空间和目标服务 Pod；存在多个匹配 Pod 时选择创建时间最新的实例并在预检中说明。
- 目标服务缺失时，通过环境本机的 YSP 接口检查产品和服务信息，经确认后补充服务并等待 Pod Ready。
- 使用 `kubectl cp` 将 `dist` 复制到容器的 `/usr/share/nginx/html/`。
- 发布前展示本地目录、主机、远程目录、命名空间、Pod 和目标路径；仅在完整流程成功后提示访问环境进行验证。

该技能会修改在线环境。执行发布前必须完成预检，并确认准确的制品、环境、远程目录、命名空间、服务和 Pod。

入口文档：[`replace-env-dist/SKILL.md`](./replace-env-dist/SKILL.md)

## 配置与凭据

- 技能运行时配置默认保存在当前用户桌面的 `agentSkillLocalConfig/` 下，不写入技能包目录。
- `puc-config` 使用独立的 PUC 环境配置；其余三个远程运维技能复用 `ssh-config/environments.local.json` 中的 SSH 登录信息。
- 各技能包只在自己的业务配置中保存日志目录、命名空间、远程目录等业务参数，不重复保存 SSH 凭据。
- 密码、Token、验证码、Cookie、IP 和真实环境配置都属于敏感信息，不应提交到仓库或输出到对话和日志中。
- 每个技能包都提供不含真实凭据的配置模板，初始化时不会覆盖用户已有配置。

## 通用安全约束

- 所有操作必须先解析到唯一、明确的目标环境。
- 读取日志等查询操作保持只读，不修改远程源文件。
- 配置写入、目录删除、Pod 重启和制品发布等变更操作必须先执行预检。
- 不猜测缺失的环境、命名空间、目录、Pod 或服务信息；存在歧义时先停止并确认。
- 不输出或在技能目录中保存密码、Token、验证码、Cookie 等敏感数据。
- 创建或发布请求失败、超时或结果不确定时不自动重试，避免重复写入和环境状态失控。

## 仓库结构

```text
puc-toolkit/
|-- README.md
|-- puc-config/             # PUC 配置与账号、人员、License 等管理
|-- get-business-log/       # 业务日志采集
|-- refresh-puc-language/   # PUC 语言资源刷新
`-- replace-env-dist/       # 前端 dist 构建与环境部署
```

每个技能包通常包含以下内容：

```text
<skill>/
|-- SKILL.md    # 技能入口、适用场景、工作流和安全约束
|-- agents/     # Agent 展示与调用配置
|-- assets/     # 配置模板等静态资源
|-- scripts/    # 预检和实际操作脚本
`-- references/ # 可选的分模块详细说明
```

具体参数、执行流程和异常处理规则以各技能包的 `SKILL.md` 为准。
