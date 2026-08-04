# 优化

codebuddy的积分消耗情况调用的是这个接口https://www.codebuddy.cn/billing/meter/get-enterprise-user-usage。返回结果如下

```
{
    "code": 0,
    "msg": "OK",
    "requestId": "505425ba-3298-4e46-b97b-b996c06cb564",
    "data": {
        "credit": 8988.44,
        "cycleStartTime": "2026-07-21 00:00:00",
        "cycleEndTime": "2026-08-20 23:59:59",
        "limitNum": 13000,
        "cycleResetTime": "2026-08-21 00:00:00"
    }
}
```

根据这两个能否调整一下。现在显示额度接口调用错误。

然后已连接，能否像antigravity一样，页显示登陆的用户。
