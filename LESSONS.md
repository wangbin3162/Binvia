# Lessons — 错题本

本文件记录**近期真正踩过的坑**，以及能拦住它的规则。**改代码前先扫一眼。**

每条错题被独立踩到 **3 次**，就说明「读一遍记不住」——把它移进
[`docs/code-standards.md`](docs/code-standards.md) 变成硬规矩，从这里删掉。
所以本文件是**故意易腐的**：它只装还没站住的东西。

**健康体量：≤ 5 条错题。** 上限按**条数**数，不按行数——本项目错题的价值恰恰在证据里
（实测对照表、可复用的 GUI 调试法、抓下来的报错原文），按行数会逼你删掉最值钱的那部分。
所以限条数、放开长度，但界是可见的：**过了 5 条就必须毕业一条，不许偷偷加。**

> 当前 3 条，未超限。

---

## 怎么写一条错题

规则要写成**祈使句**，放在最前面。Agent 读的是指令，不是散文。
证据必须能回溯。做过对的也要记——否则清单会退化成「只教别做什么」的焦虑清单。

```markdown
## <错误类型，不是模块名>

**<规则：改 X 之前必须做 Y。一句话，祈使句>**
- 症状：<用户看到的现象 / 报错原文>
- 根因：<为什么>
- 证据：<commit sha 或 日期 + 文件路径> / <谁报的> / <当时发生了什么>
- 复发 N 次
- ✅ 做对了：<某次做对的例子，照这个来>
```

按**错误类型**分组（比如「布局」「并发」「配置读写」），不要按模块分。
按类型分，读到的是「这一类错的通病」；按模块分，读到的是「N 个孤立事故」。

---

## SwiftUI 布局

### Form(.grouped) 里的 TextField 必须加 `.labelsHidden()`

**改 macOS `Form(.grouped)` 里的 `TextField` 时，先确认它有 `.labelsHidden()`；否则它不认宽度约束，塌缩成由 prompt/内容决定的固有宽度。**

- 症状：`SettingsProviderPane` 模型列表区输入框与表头对不齐、撑不开——
  设了 `.frame(width: 200)` 的「菜单显示名」实际只有 ~110pt；
  「实际请求模型」列看似 `maxWidth: .infinity` 却只有 ~92pt；
  「上下文窗口」宽度随内容变化（49~70pt），与表头完全错位。
- 根因：`Form(.grouped)` 对**没有 `.labelsHidden()` 的 `TextField`** 走标签式测量路径，
  字段按 `LabeledContent` 语义排布，塌缩到由 prompt 占位文字/当前内容决定的固有宽度，
  任何 `.frame(width:)` / 有限 `.frame(maxWidth:)` 都被忽略。
- 证据：`Sources/BinviaApp/Views/Settings/SettingsProviderPane.swift`，2026-08-07（56526cb）；
  对照实测（在真实 Form 里读 `NSTextField` 的 frame）：

  | 写法 | 实际渲染宽度 |
  |---|---|
  | `.frame(width: 200)` | **110**（无视） |
  | `.frame(maxWidth: 200)` | **110**（无视） |
  | `.frame(width: 200)` + `.labelsHidden()` | **200** ✅ |
  | `.frame(minWidth: 200, maxWidth: .infinity)` | 撑满（≥200）✅ |
  | 无任何 frame（裸字段） | 撑满剩余 ✅ |

- 修复：加 `.labelsHidden()`，放在 `.font(.footnote)` 之前：

  ```swift
  TextField("", text: displayNameBinding(for: entry, index: index), prompt: Text("菜单显示名"))
      .labelsHidden()          // ← 必须有，否则 Form 无视下面这行
      .font(.footnote)
      .textFieldStyle(.roundedBorder)
      .frame(width: modelDisplayNameWidth, alignment: .leading)
  ```

  「裸字段 + 撑满剩余」正是 `tokenAddRow` 里 SecureField 一直正常的原因——令牌行都有 `.labelsHidden()`。
- 复发 1 次
- ✅ 做对了：本机终端既无 Screen Recording 也无 Accessibility 权限，无法截图/AX 取 frame，
  于是沉淀出一套**纯进程内**验证法，GUI 布局类改动都可复用：
  1. `ImageRenderer` 离屏渲染——裸布局可用；`Form(.grouped)` 渲染不出控件，仅用于验证布局原语。
  2. **`NSHostingView` + 自进程 NSView 树遍历（最终答案）**：写个最小 `NSApplication` 宿主真实 `Form`，
     `layoutSubtreeIfNeeded()` 后递归遍历视图树，直接读 `NSTextField` 的真实 frame——**无任何权限要求**。
  3. `bitmapImageRepForCachingDisplay` + Vision OCR——宿主窗口 `cacheDisplay` 离屏成图（同样免权限），
     再跑 `VNRecognizeTextRequest` 读文字像素坐标核对对齐。
  对照实验设计：同一 Form 里并排渲染 A~F 六种宽度写法，一次跑完即得结论。

---

## 列表与状态

### 列表增删改一律按索引定位，不要按业务键匹配

**操作列表条目时用索引（`at index: Int`）定位，不要按业务唯一键（如 `modelName`）匹配——条目可重名。**

- 症状：`SettingsProviderPane` 模型列表里——
  新增两个同名模型后删一个，`removeAll { $0.modelName == ... }` 把**两个都删了**；
  下拉填充/编辑字段时 `firstIndex(where:)` 在重名时定位到**第一行**，改错行、覆盖错数据；
  `ForEach(modelEntries)` 隐式用 `id: modelName`（`ProviderModelEntry.id` 就是 modelName），
  重名时行 ID 冲突，SwiftUI 视图复用错乱。
- 根因：把**显示用业务字段**当成了**唯一标识**。模型名是用户可重复输入的，
  不满足唯一性；一旦当作 `id` 或匹配键，所有按它定位的操作都会命中错行。
- 证据：`Sources/BinviaApp/AppState.swift` + `SettingsProviderPane.swift`，2026-08-07（56526cb）。
- 修复：`AppState.removeUserModel / updateUserModel / removeCustomModel / updateCustomModel`
  签名改为 `at index: Int`，内部用 `remove(at:)` / `[index]` 定位；
  `SettingsProviderPane` 全部操作带 index，行渲染用 `ForEach(Array(modelEntries.enumerated()), id: \.offset)`。
- 复发 1 次

**规律**：SwiftUI `ForEach` 的 `id` 必须**稳定唯一**。数据模型 `Identifiable.id` 若取业务字段，
务必确认该字段在列表内唯一，否则要么改 id，要么用 `enumerated()` + offset 并在操作时传索引。

---

## 文档与数字

### 不要把手写的测试数/断言数写进文档和 CI 注释

**写文档或 CI 注释时不要写死测试数量，指向「运行 `make test` 看的末行输出」；数字一定会腐坏。**

- 症状：同一个断言数被复制在 `docs/build-release-guide.md` 与 `.github/workflows/*.yml` 的 6 处，
  每处都不准，且**互相矛盾**——2026-10-13 实测 `swift run BinviaCheck` 输出 `passed=844, failed=0`，
  而当时仓库里同时写着 **647**（ci.yml ×1）、**591**（guide 命令表 ×1）、**464**（release.yml ×2、guide ×2）三个版本。
  即：同一仓库同一时刻对同一个数字有四种说法，其中三种是错的。
- 根因：断言数随每次加测试单调增长，而它被复制粘贴在**多个与测试代码不相邻的地方**；
  没有任何机制在数字失效时报警，只能靠人发版时想起来顺手改——而每次只改一部分，
  于是旧数字留在别处，越积越多。
- 证据：`5e552d2`（2026-08-06，标题即「测试数修正为 647」，把 698 改成 647，
  同一提交里改 `.github/workflows/ci.yml`、`release.yml`、`docs/build-release-guide.md` 三处）；
  `d4ac5a2` 首次写入 698；更早/更晚的 464、591 各自残留至今。
  **同一条已独立复发 ≥2 次**（698→647 一次，647/591/464 各自漂移一次），2026-10-13 本次修正为第三种写法。
- 复发 2 次
- ✅ 做对了：`Scripts/build.sh` 与 CI 直接**执行** `BinviaCheck` 并以退出码判定成败，
  不依赖任何写死的数字——这才是可靠的判据。文档要提数量，就写「以运行输出为准」。

---

## 毕业记录

已毕业进 [`docs/code-standards.md`](docs/code-standards.md) 的条目（这里只留指针，正文在标准里）：

- {{暂无}}
