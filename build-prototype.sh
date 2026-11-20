#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT

xcodegen generate
swiftc Sources/FocusCore.swift Checks/main.swift -o "$work_dir/focus-checks"
"$work_dir/focus-checks"

xcodebuild -project PocketFocus.xcodeproj -scheme PocketFocus \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$work_dir/device" CODE_SIGNING_ALLOWED=NO build

mkdir -p "$work_dir/Payload" dist
ditto "$work_dir/device/Build/Products/Release-iphoneos/PocketFocus.app" "$work_dir/Payload/PocketFocus.app"
ditto -c -k --keepParent "$work_dir/Payload" dist/PocketFocus-prototype-unsigned.ipa
shasum -a 256 dist/PocketFocus-prototype-unsigned.ipa > dist/SHA256SUMS.txt

if [[ "${1:-}" == "--simulator-evidence" ]]; then
  xcodebuild -project PocketFocus.xcodeproj -scheme PocketFocus \
    -configuration Release -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$work_dir/simulator" CODE_SIGNING_ALLOWED=NO build
  simulator_id="$(
    xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime in sorted(devices, reverse=True):
    iphones = [d for d in devices[runtime] if d["name"].startswith("iPhone")]
    if iphones:
        device = next((d for d in iphones if d["name"] == "iPhone 12 Pro"), iphones[0])
        print(device["udid"])
        break
'
  )"
  test -n "$simulator_id"
  xcrun simctl bootstatus "$simulator_id" -b
  xcrun simctl status_bar "$simulator_id" override --time '9:41' --batteryState unplugged --batteryLevel 100
  xcrun simctl install "$simulator_id" "$work_dir/simulator/Build/Products/Release-iphonesimulator/PocketFocus.app"
  xcrun simctl launch "$simulator_id" com.pocketfocus.personal
  sleep 4
  xcrun simctl io "$simulator_id" screenshot dist/simulator-no-lidar.png
  xcrun simctl list devices booted > dist/simulator-device.txt
fi
