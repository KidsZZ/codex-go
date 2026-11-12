# 安全说明 / Security

Codex Go 是连接你自己开发环境的 SSH 客户端。远端代码执行权限由你在 Codex 中选择的权限策略和 SSH 账号权限决定；客户端不提供额外的远端沙箱。

## 数据与连接边界

- 首次连接需要确认 SSH 主机指纹，已记录的指纹不一致时会拒绝连接。
- SSH 凭据、主机配置、草稿与会话缓存通过系统安全存储保存；Android 备份已关闭。
- 远端 Codex 登录由远端环境管理，客户端不附带共享账号、API 密钥或开发者主机地址。
- app-server 的访问经过 SSH，手机上的桥接服务只监听回环地址。不要为了使用本应用把 app-server 直接暴露到公网。
- 附件会上传到你连接的远端环境；下载和导出的文件由 Android 的文件选择或保存流程处理。
- 本地诊断日志不会记录完整 RPC 正文，但错误、路径、服务信息或截图仍可能包含敏感内容。发布日志前请人工检查。

本项目处于预览阶段。优先使用最新发布版本，目前没有长期维护的旧版本安全分支。

## 报告漏洞

不要在公开 Issue 中直接发布密钥、访问令牌、私人对话或可用于访问真实主机的细节。

如果仓库的 Security 页面提供 **Report a vulnerability**，请使用 GitHub 的私密漏洞报告。该入口需要维护者在仓库设置中启用；若入口尚未提供，请只创建一个不含漏洞细节的 Issue，请求私下联系后再发送材料。

报告中可包含受影响版本、脱敏后的复现步骤、预期和实际行为、影响范围。不要为复现问题提供真实凭据。

## English

Codex Go connects to infrastructure you control. Remote execution is governed by the SSH account and Codex permission policy; the app does not add a separate remote sandbox.

SSH host fingerprints are checked, credentials and cached workspace state use platform secure storage, Android backup is disabled, and the local app-server bridge binds to loopback. Remote Codex authentication remains on the remote host. Attachments are transferred to that host, and exported files leave the app's private storage through Android file flows.

Diagnostics omit full RPC payloads, but errors, paths, and screenshots can still contain sensitive information. Review material before sharing it.

Prefer GitHub private vulnerability reporting when the repository has enabled it. If **Report a vulnerability** is unavailable, open a public issue requesting private contact without disclosing exploit details or secrets. Include sanitized reproduction steps, the affected version, and impact. Security fixes target current releases; older versions do not have a separate long-term support branch.
