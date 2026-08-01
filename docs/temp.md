后续功能规划：

1. 模型测试目前只能一个个点，能否增加一个测试全部模型的按钮，然后点击后，自动测试全部模型，并给出测试结果。
2. 模型目前只要供应商接入成功后。默认是所有模型都接入，能否增加一个选项，选择哪些模型接入。这部分可以在网关API密钥后增加一个配置。默认是全部接入。这部分可参考omniroute的配置，不同供应商请增加模型前缀，如cbcn/deepseek-v4-flash 、agy/xxx、ds/xxx这样，区分供应商。
3. 供应商接入成功后，能否增加一个用量显示，显示该供应商的用量情况。比如deepseek，显示余额，以及使用量。这部分可参考codexbar的实现。
4. antigravity 供应商接入成功后，能否增加一个用量显示，显示该供应商的用量情况。用量情况可参考omniroute中的实现。
5. codebuddy-cn 供应商接入成功后，能否增加一个用量显示，显示该供应商的用量。这里omniroute也没能查询用量，能否参考codebuddy的网页登录获取用量。
6. 生成密钥现在时sk-tg开头的，现在改为sk-bv开头的。
7. 根据供应商的模型，自动生成模型列表。这部分可参考codexbar的实现。
8. 根据omniroute的openai实现，接入omniroute的openai api。
9. 根据omniroute的api供应商接入。计划支持opencode、opencode go、kimi、z.ai、minimax、xiaomimimo、qwen的接入。
10. 实现这些供应商的接入后，希望能参考codexbar，实现codexbar的余额/用量展示。

以上需求，作为二期实现要素。帮我分析工程现状。制定一个开发计划书，不明确的调用grill-me和我对齐需求。最终输出一个开发计划书，包括需求分析、开发计划、开发进度、开发成果等。放到docs目录。
