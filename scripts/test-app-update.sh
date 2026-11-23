#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/mac-to-galaxy-update-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
export M2G_TEST_FIXTURE="$fixture"
export M2G_TEST_OLD=1111111111111111111111111111111111111111
export M2G_TEST_NEW=2222222222222222222222222222222222222222
mkdir -p "$fixture/archive/scripts"
cp "$repo_dir/Resources/Info.plist" "$fixture/template.plist"

cat > "$fixture/archive/scripts/build-app.sh" <<'SH'
#!/bin/bash
set -euo pipefail
if [[ "$(cat "$M2G_TEST_FIXTURE/scenario")" == build-fails ]]; then
    exit 4
fi
app="$(cd "$(dirname "$0")/.." && pwd)/dist/Mac-to-galaxy.app"
mkdir -p "$app/Contents/MacOS"
cp /usr/bin/true "$app/Contents/MacOS/MacToGalaxy"
cp "$M2G_TEST_FIXTURE/template.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :MacToGalaxyRevision string $MAC_TO_GALAXY_REVISION" "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app" >/dev/null 2>&1
SH

cat > "$fixture/gh" <<'SH'
#!/bin/bash
set -euo pipefail
[[ "${1:-}" == api && "${2:-}" == --hostname && "${3:-}" == github.com ]]
scenario="$(cat "$M2G_TEST_FIXTURE/scenario")"
case "${4:-}" in
    repos/ljwoo8942/Mac-to-galaxy/git/ref/heads/main)
        [[ "${5:-}" == --jq && "${6:-}" == .object.sha ]]
        case "$scenario" in
            current) printf '%s\n' "$M2G_TEST_OLD" ;;
            invalid) printf '%s\n' bad-revision ;;
            *) printf '%s\n' "$M2G_TEST_NEW" ;;
        esac
        ;;
    "repos/ljwoo8942/Mac-to-galaxy/tarball/$M2G_TEST_NEW")
        [[ "$scenario" == update || "$scenario" == build-fails ]]
        cat "$M2G_TEST_FIXTURE/source.tar.gz"
        ;;
    *) exit 3 ;;
esac
SH
chmod +x "$fixture/gh"
printf '%s\n' current > "$fixture/scenario"
MAC_TO_GALAXY_REVISION="$M2G_TEST_OLD" /bin/bash "$fixture/archive/scripts/build-app.sh"
mv "$fixture/archive/dist/Mac-to-galaxy.app" "$fixture/Existing.app"
rmdir "$fixture/archive/dist"
/usr/bin/tar -czf "$fixture/source.tar.gz" -C "$fixture" archive

cat > "$fixture/main.swift" <<'SWIFT'
import Foundation

let environment = ProcessInfo.processInfo.environment
let root = URL(fileURLWithPath: environment["M2G_TEST_FIXTURE"]!)
let oldRevision = environment["M2G_TEST_OLD"]!
let newRevision = environment["M2G_TEST_NEW"]!
let installed = root.appendingPathComponent("Existing.app")
let github = root.appendingPathComponent("gh")

func scenario(_ name: String) throws {
    try Data(name.utf8).write(to: root.appendingPathComponent("scenario"))
}

func update() throws -> PreparedAppUpdate? {
    try AppUpdater.prepare(appAt: installed, runningRevision: oldRevision, githubCLI: github)
}

func installedRevision() throws -> String? {
    let data = try Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
    let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    return info?[AppUpdater.revisionKey] as? String
}

let upToDate = try update()
precondition(upToDate == nil)
for unsuccessful in ["invalid", "build-fails"] {
    try scenario(unsuccessful)
    do {
        _ = try update()
        fatalError("Expected update failure for \(unsuccessful)")
    } catch is AppUpdateError {}
    let afterFailure = try installedRevision()
    precondition(afterFailure == oldRevision)
}

try scenario("update")
let prepared = try update()!
let beforeSwap = try installedRevision()
precondition(beforeSwap == oldRevision)
do {
    _ = try update()
    fatalError("Expected the second update to respect the existing lock")
} catch let error as AppUpdateError {
    precondition(error.message.contains("업데이트 중"))
}
try prepared.exchangeBundles()
let afterSwap = try installedRevision()
precondition(afterSwap == newRevision)
let updated = try AppUpdater.prepare(appAt: installed, runningRevision: newRevision, githubCLI: github)
precondition(updated == nil)
try prepared.exchangeBundles()
let afterRollback = try installedRevision()
precondition(afterRollback == oldRevision)
prepared.discardReplacement()
print("App update checks passed")
SWIFT

export CLANG_MODULE_CACHE_PATH="$fixture/modules"
/usr/bin/swiftc -swift-version 5 -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    "$repo_dir/Sources/MacToGalaxy/AppUpdater.swift" "$fixture/main.swift" -o "$fixture/check"
"$fixture/check"
