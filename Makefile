.PHONY: build test run dist release icon clean doctor

build:
	swift build

test:
	swift test

run: dist
	open dist/iRecord.app

dist:
	./scripts/build.sh

release:
	./release.sh

icon:
	rm -rf Resources/AppIcon.iconset
	swift scripts/make_icon.swift Resources/AppIcon.iconset
	iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns

clean:
	swift package clean
	rm -rf dist

doctor:
	./dist/irecord doctor --json || true
