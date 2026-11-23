#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
    printf '%s\n' '이 앱은 macOS에서 빌드해야 합니다.' >&2
    exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
    printf '%s\n' 'Xcode 또는 Command Line Tools를 설치하세요. xcode-select --install' >&2
    exit 1
fi

if ! command -v brew >/dev/null || ! command -v pkg-config >/dev/null || ! brew list --versions libmtp >/dev/null; then
    printf '%s\n' 'Homebrew와 의존성을 설치하세요. brew install libmtp pkgconf' >&2
    exit 1
fi

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

revision="${MAC_TO_GALAXY_REVISION:-}"
if [[ -z "$revision" && -e .git && -z "$(git status --porcelain --untracked-files=all)" ]]; then
    revision="$(git rev-parse HEAD)"
fi
if [[ -n "$revision" && ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s\n' '앱의 Git 커밋 번호가 올바르지 않습니다.' >&2
    exit 1
fi

export PKG_CONFIG_PATH="$(brew --prefix libmtp)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
if ! pkg-config --exists 'libmtp >= 1.1.22'; then
    printf '%s\n' 'libmtp 1.1.22 이상을 설치하세요. brew install libmtp' >&2
    exit 1
fi

swift build --configuration release --product MacToGalaxy
bin_dir="$(swift build --configuration release --show-bin-path)"

mkdir -p "$repo_dir/dist"
staging_dir="$(mktemp -d "$repo_dir/dist/.build-app.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
staging_app="$staging_dir/Mac-to-galaxy.app"
app_path="$repo_dir/dist/Mac-to-galaxy.app"
mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Resources"
cp "$bin_dir/MacToGalaxy" "$staging_app/Contents/MacOS/MacToGalaxy"
cp "$repo_dir/Resources/Info.plist" "$staging_app/Contents/Info.plist"
cp "$repo_dir/Resources/AppIcon.icns" "$staging_app/Contents/Resources/AppIcon.icns"
if [[ -n "$revision" ]]; then
    /usr/libexec/PlistBuddy -c "Add :MacToGalaxyRevision string $revision" "$staging_app/Contents/Info.plist"
fi
plutil -lint "$staging_app/Contents/Info.plist"
codesign --force --sign - "$staging_app"
codesign --verify --strict "$staging_app"

if [[ -e "$app_path" || -L "$app_path" ]]; then
    mv "$app_path" "$staging_dir/previous.app"
fi
if ! mv "$staging_app" "$app_path"; then
    if [[ -e "$staging_dir/previous.app" || -L "$staging_dir/previous.app" ]]; then
        mv "$staging_dir/previous.app" "$app_path"
    fi
    exit 1
fi
printf '%s\n' "$app_path"
