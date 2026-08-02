# 主面板优化

主面板展开现在只能看到usage和服务开关，现在希望针对主面板进行优化，首页显示概况，并且提供服务开关和用量统计。这部分都参考codexbar。

采用tab方式展示已接入的供应商，展示余额或者用量。

---

供应商面板需要做一些调整。以deepseek为例。（所有样式都参考codexbar样式）

1. 所有供应商均有信息面板，展示别名url等信息。这部分我希望基础信息和供应商最上方的logo以及开关放到一起，参考codexbar，切启用禁用样式也同步codexbar。
2. 基础信息下方显示用量（显示余额/用量）如deepseek，参考codexbar余额标签在左，实际余额在右
3. 用量下方展示API 令牌。现在叫做“连接”。令牌参考codexbar。默认两个输入，输入标签+密钥，然后右侧显示“添加”按钮，添加成功后显示标签和右侧移除。至于类似codebuddy都，Access Token，则把API 令牌，更换成Access Token即可。
4. 主面板的设置和退出按钮，我发现有时候要点多次才能触发，这部分帮我检查一下。
5. 目前测试成功后，我使用密钥提供给opencode使用，选择模型后，发送消息都显示Not Found: Not Found

---

部分优化。

1. 针对antigravity供应商的优化：目前oauth的登陆后，没能显示当前登陆账号。这里我希望参考omniroute中，可以刷新token，我现在发现每次打开的时候antigravity都需要重新连接。
2. z.ai 我现在是中国区https://bigmodel.cn/ 的apikey。所以这里帮我修改一下默认中国区的实现。然后参考codexbar，这里API 令牌上方增加一个连接。选择API区域
3. z.ai的API区域，支持选择Global（api.z.ai）国际站，默认BigModel CN (open.bigmodel.cn) 中国区
4. 通用配置中，测试放到网关密钥页签下面。
5. OpenCode 的接入，目前点击测试连接的时候，模型列表还是没能拉取最新模型。测试默认模型的时候提示Missing credentials:OPENCODE_API_KEY or config providers.opencode.credenital.apiKey，关于OpenCode 的接入，参考omniroute中OpenCode Zen 的实现。拉取模型。

以上问题帮我分析，制定修改计划。有疑问grill-me 对齐需求。
