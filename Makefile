# Binvia 常用命令

.PHONY: build test release run clean

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
