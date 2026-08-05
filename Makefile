# Binvia 常用命令

.PHONY: build test release run clean web rust-build rust-test rust-release

build:
	swift build

# 自包含可运行测试（零依赖断言框架，本机无需 Xcode/xctest）
test:
	swift run BinviaCheck

release:
	./Scripts/build.sh

run:
	swift run BinviaServer

clean:
	rm -rf .build bin

# Web 面板构建：安装依赖 → 构建前端 → 内嵌生成 Swift 源码
# 修改前端后必须运行此命令，并将生成的 WebPanelAssets.swift 一起提交
web:
	cd web && npm install && npm run build && node scripts/embed.mjs

rust-build:
	cargo build --manifest-path binvia-core/Cargo.toml

rust-test:
	cargo test --manifest-path binvia-core/Cargo.toml --workspace

rust-release:
	./Scripts/build-rust.sh
