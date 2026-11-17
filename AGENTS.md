# 开发与发布
- 中文沟通；不新增测试文件或任务总结文档。提交前运行 `bash tool/check.sh`，涉及中转时运行 `npm run check --prefix packages/remote_bridge`。
- 用户委托“开发并发布 Beta”时，包含本次相关改动的提交、推送和 Beta 发布；普通分析不改代码，不擅自包含其他人的改动。禁止提交凭据、`.env` 和安装包。
- 正式版 `dev.codexgo.app`，Beta `dev.codexgo.app.beta`；各自更新，沿用固定发布密钥。
- `pubspec.yaml` 保存下一正式版本及递增基础构建号；发布脚本自动编号 Beta。提交并推送后用 `node tool/release.mjs beta`，等待工作流成功并确认 APK/元数据齐全。
- 正式发行必须得到用户确认，并指定验收通过的 Beta：`node tool/release.mjs release --beta <标签> --publish`。省略 `--publish` 生成草稿；用户也可在 Actions 的 Release 页面填写相同参数。
- 正式版只能从该 Beta 的源码提交构建；不移动旧标签、不覆盖已有发行包。Beta 允许公开预发布，正式发行与生产服务变更不能由 Beta 授权代替。
- 中转 Beta 使用独立进程、令牌和 Host 身份目录；部署后检查健康和配对链路，保留回滚版本，不影响现有 dsh 服务。
