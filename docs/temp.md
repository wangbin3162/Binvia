# Binvia Web 面板开工提示词

> 用法：新开一个对话，把下面 ``` 之间的内容整段粘贴给 AI 即可开始。
> 背景：Binvia 是 macOS 本地 AI 网关（Swift，零第三方依赖），v0.1.2 已发布。
> 本任务：实现内置 Web 管理面板（Vite + Vue3 + TS + Tailwind），替代 Windows 计划的废弃内容。

---

```
你将在 Binvia 仓库实施 Web 管理面板。开工前先完整阅读这两个文件，严格按其执行：

1. docs/web-panel-plan.md —— 实现计划（技术决策 / 架构 / admin API 规格 / 实施切片 / 测试 / 风险）
2. AGENTS.md —— 仓库规范（构建命令 / 编码风格 / 测试方式 / 提交约定）

【任务目标】
按计划的 S1→S5 切片顺序实施，每片完成后验证通过再进入下一片，不要跳步、不要超范围：

- S1 后端骨架：ServerState（配置盒 + 热更新回调 + admin token）、RouteConfig 新增
  webPanelEnabled / adminPassword、normalizePath 放行 /admin 前缀、GET / 返回占位
  HTML、BinviaServer/main.swift 接线（复用 HTTPServer.setHandler 热更新）
- S2 admin API：全部端点（overview / entries / providers / snapshots / config /
  usage/refresh / providers/*/test / keys）+ 可选密码认证 + 凭据掩码 + 热更新生效 +
  webPanelEnabled=false 时 404 + BinviaCheck 新增 WebPanelTests 套件
- S3 前端脚手架：web/ 工程（Vite + Vue3 + TypeScript + TailwindCSS v4 的
  @tailwindcss/vite 插件，不引 UI 组件库）+ vite dev proxy → 127.0.0.1:20427 +
  顶栏 + 概览 Tab（Summary 卡片 + Provider 健康度）
- S4 前端全量：Provider / 请求日志 / 网关 Keys / 设置 四个 Tab + 密码登录流程 +
  2s 轮询 + toast 反馈，全部对齐现有 GUI 的信息架构
- S5 内嵌与发布：web/scripts/embed.mjs（vite build 产物内联成单文件 HTML →
  base64 写入 Sources/BinviaCore/Server/WebPanelAssets.swift）+ Makefile 增加
  make web 目标 + build.sh 集成 + README / docs/build-release-guide.md 更新

【硬性约束】
- Swift 零第三方依赖（零依赖指运行时；vite/vue/typescript/tailwindcss 仅构建期）
- 代码注释用中文；4 空格缩进；所有 target 保持 StrictConcurrency
- 测试写入 Sources/BinviaCheck/main.swift（自包含断言框架，无 XCTest），
  运行方式：make test（= swift run BinviaCheck）
- 不得改变 /v1/* 网关路由行为；注意 RouteHandler.normalizePath 的 /admin 放行回归点
- 改动前端后必须运行 make web，并把重新生成的 WebPanelAssets.swift 一起提交
- 每个切片提交一次，conventional commit 风格（英文标题 + 中文正文）

【每片验证方式】
- S1/S2：make test 全绿 + curl http://localhost:20427/ 与 /admin/api/overview 验证
- S3/S4：cd web && npm run dev 联调（浏览器走查，对照 GUI 行为）
- S5：make release 产物（DMG/tar.gz 内 BinviaServer）单文件包含面板，无需附带前端文件

【最终验收】
1. make test 全绿（含 WebPanelTests，无回归）
2. BinviaApp --smoke-test 通过（GUI 无回归）
3. 浏览器打开 http://127.0.0.1:20427/ 五个 Tab 全部可用，配置保存即时热更新生效
4. web_panel_enabled=false 时 / 与 /admin/* 返回 404，/v1/* 不受影响
5. 全程 git 提交规范，最后推送 main 触发 CI 并确认绿
```
