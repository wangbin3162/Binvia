# Lessons — 踩坑记录

本文件记录 Binvia 开发中踩过的坑与沉淀下来的经验，**改代码前先扫一眼**，避免重复踩坑。

## SwiftUI：macOS `Form(.grouped)` 里 TextField 无视 `.frame(width:)`

> 一句话：**Form 里的 TextField 必须加 `.labelsHidden()` 才会尊重宽度约束，否则塌缩成由 prompt/内容决定的固有宽度。**

### 症状

`SettingsProviderPane` 模型列表区，输入框与表头文字对不齐、撑不开实际宽度：

- 设置了 `.frame(width: 200)` 的「菜单显示名」输入框实际只有 ~110pt 宽；
- 「实际请求模型」列看似 `maxWidth: .infinity` 却只有 ~92pt；
- 「上下文窗口」宽度随内容变化（49~70pt），与表头完全错位。

### 根因

macOS 的 `Form(.grouped)` 对「**没有 `.labelsHidden()`** 的 `TextField`」走标签式测量路径：字段被按 `LabeledContent` 语义排布，塌缩到由 **prompt 占位文字 / 当前内容** 决定的固有宽度，任何 `.frame(width:)` / `.frame(maxWidth:)`（有限值）都被忽略。

对照实测（在真实 Form 里读 `NSTextField` 的 frame）：

| 写法 | 实际渲染宽度 |
|---|---|
| `.frame(width: 200)` | **110**（无视） |
| `.frame(maxWidth: 200)` | **110**（无视） |
| `.frame(width: 200)` + `.labelsHidden()` | **200** ✅ |
| `.frame(minWidth: 200, maxWidth: .infinity)` | 撑满（≥200）✅ |
| 无任何 frame（裸字段） | 撑满剩余 ✅ |

「裸字段 + 撑满剩余」正是 `tokenAddRow` 里 SecureField 一直正常的原因——令牌行都有 `.labelsHidden()`。

### 修复

模型列表的三个输入框（菜单显示名 / 实际请求模型 / 上下文窗口）统一加上 `.labelsHidden()`，位于 `.font(.footnote)` 之前：

```swift
TextField("", text: displayNameBinding(for: entry, index: index), prompt: Text("菜单显示名"))
    .labelsHidden()          // ← 必须有，否则 Form 无视下面这行
    .font(.footnote)
    .textFieldStyle(.roundedBorder)
    .frame(width: modelDisplayNameWidth, alignment: .leading)
```

修复后实测：200pt / 撑满剩余 / 90pt，表头与字段左缘完全对齐。

### 验证方法（无需屏幕录制/辅助功能权限的 GUI 调试法）

本机终端既无 Screen Recording 也无 Accessibility 权限，无法直接截图/AX 取 frame。沉淀出一套**纯进程内**验证法，GUI 布局类改动都可复用：

1. **`ImageRenderer` 离屏渲染**：把目标 View 喂给 `ImageRenderer` 渲染成 PNG——裸布局可用；`Form(.grouped)` 渲染不出控件，仅用于验证布局原语。
2. **`NSHostingView` + 自进程 NSView 树遍历**（最终答案）：写个最小 `NSApplication` 宿主真实 `Form`，`layoutSubtreeIfNeeded()` 后递归遍历视图树，直接读 `NSTextField` 的真实 frame——**无任何权限要求**，因为查的是自己进程的视图树。
3. **`bitmapImageRepForCachingDisplay` + Vision OCR**：宿主窗口 `cacheDisplay` 离屏成图（同样免权限），再跑 `VNRecognizeTextRequest` 读表头/字段文字的像素坐标，核对对齐。

对照实验设计：同一 Form 里并排渲染 A~F 六种宽度写法，一次跑完即得结论。

---

## SwiftUI：列表操作按「模型名」定位会误伤重名条目

> 一句话：**列表增删改一律按索引定位，不要按业务唯一键（如 modelName）匹配——条目可重名。**

### 症状

`SettingsProviderPane` 模型列表：

- 新增两个同名模型后删一个，`removeAll { $0.modelName == ... }` 把**两个都删了**；
- 下拉填充/编辑字段时，`firstIndex(where: { $0.modelName == ... })` 在重名时定位到**第一行**，改错行、覆盖错数据；
- `ForEach(modelEntries)` 隐式用 `id: modelName`（`ProviderModelEntry.id` 就是 modelName），重名时行 ID 冲突，SwiftUI 视图复用错乱。

### 修复

- `AppState.removeUserModel / updateUserModel / removeCustomModel / updateCustomModel` 签名改为 `at index: Int`，内部 `remove(at:)` / `[index]` 定位；
- `SettingsProviderPane` 全部操作带 index，行渲染用 `ForEach(Array(modelEntries.enumerated()), id: \.offset)`。

### 规律

SwiftUI `ForEach` 的 `id` 必须是**稳定唯一**的；数据模型 `Identifiable.id` 若取业务字段，务必确认该字段在列表内唯一，否则要么改 id，要么用 enumerated + offset 并在操作时传索引。
