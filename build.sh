#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
root="$PWD"
mkdir -p build

swift_flags=(-target "$(uname -m)-apple-macosx14.0" -parse-as-library)
# 旧版 CLT 更新后可能同时留下两个 SwiftBridging 定义。只在构建进程里屏蔽旧/重复定义。
swift_headers="$(xcode-select -p)/usr/include/swift"
if [[ -f "$swift_headers/module.modulemap" && -f "$swift_headers/bridging.modulemap" ]] &&
   grep -q 'module SwiftBridging' "$swift_headers/module.modulemap" &&
   grep -q 'module SwiftBridging' "$swift_headers/bridging.modulemap"; then
    : > build/empty.modulemap
    /usr/bin/plutil -create xml1 build/clang-vfs.plist
    /usr/bin/plutil -insert version -integer 0 build/clang-vfs.plist
    /usr/bin/plutil -insert use-external-names -bool NO build/clang-vfs.plist
    /usr/bin/plutil -insert roots -json '[{"type":"directory","contents":[{"type":"file","name":"bridging.modulemap"}]}]' build/clang-vfs.plist
    /usr/bin/plutil -insert roots.0.name -string "$swift_headers" build/clang-vfs.plist
    /usr/bin/plutil -insert roots.0.contents.0.external-contents -string "$root/build/empty.modulemap" build/clang-vfs.plist
    /usr/bin/plutil -convert json -o build/clang-vfs.json build/clang-vfs.plist
    vfs="$root/build/clang-vfs.json"
    swift_flags+=(-vfsoverlay "$vfs" -Xcc -ivfsoverlay -Xcc "$vfs" -module-cache-path "$root/build/swift-cache")
fi

if [[ "${1:-}" == --test ]]; then
    xcrun swiftc "${swift_flags[@]}" Sources/OverlayPolicy.swift Tests/DisplayPolicyTests.swift -o build/display-tests
    build/display-tests
    xcrun swiftc "${swift_flags[@]}" Sources/OverlaySurface.swift Tests/OverlaySurfaceTests.swift -o build/surface-tests
    build/surface-tests
    xcrun swiftc "${swift_flags[@]}" Sources/QuotaClient.swift Tests/QuotaClientTests.swift -o build/quota-tests
    build/quota-tests
    exit
fi

app="build/Codex 额度浮窗.app"
mkdir -p "$app/Contents/MacOS"
cp Info.plist "$app/Contents/Info.plist"
xcrun swiftc "${swift_flags[@]}" -O Sources/*.swift -o "$app/Contents/MacOS/CodexQuotaOverlay"
/usr/bin/codesign --force --sign - "$app"
printf '%s\n' "$root/$app"
