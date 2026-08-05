// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Binvia",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "BinviaCore", targets: ["BinviaCore"]),
        .executable(name: "BinviaServer", targets: ["BinviaServer"]),
        .executable(name: "BinviaCLI", targets: ["BinviaCLI"]),
        .executable(name: "BinviaApp", targets: ["BinviaApp"]),
    ],
    targets: [
        // 核心库：Provider 协议/注册表、路由、认证、配置、监控、上游 HTTP 客户端
        .target(
            name: "BinviaCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
        // 本地代理服务器（原生 socket + SSE 流式转发）
        .executableTarget(
            name: "BinviaServer",
            dependencies: ["BinviaCore"],
            path: "Sources/BinviaServer",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
        // CLI：serve / providers / test / config
        .executableTarget(
            name: "BinviaCLI",
            dependencies: ["BinviaCore"],
            path: "Sources/BinviaCLI",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
        // 自包含可运行测试（零依赖断言框架，无 XCTest）。
        // 本机仅装了 CommandLineTools（无 xctest），`swift test` 不可用；
        // 用 `swift run BinviaCheck` 跑全部检查（make test 已指向该命令）。
        .executableTarget(
            name: "BinviaCheck",
            dependencies: ["BinviaCore"],
            path: "Sources/BinviaCheck",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
        // 菜单栏 GUI 应用（SwiftUI + AppKit，仅依赖 BinviaCore，Core 无 UI 依赖）。
        // 支持 `--smoke-test` 无界面自检（启动服务器→健康检查→停服）。
        // 注：Provider 品牌 SVG 图标已编译期内嵌（ProviderIcons.swift），不再声明 resources，
        // 避免 SPM 资源包在手工打包 .app 时丢失（Bundle.module 崩溃）与 codesign 冲突。
        .executableTarget(
            name: "BinviaApp",
            dependencies: ["BinviaCore"],
            path: "Sources/BinviaApp",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
    ]
)
