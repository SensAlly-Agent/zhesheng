#!/bin/bash
# Packs apps/折声.app into a drag-to-install disk image, dist/折声-<version>-build<N>.dmg, for
# Macs that have nothing installed: Apple silicon, macOS 27 or later, no Xcode. The model is inside the app already.
#
#   tools/make_dmg.sh
#       ad-hoc signature (no Apple account needed). A downloaded copy needs one approval on its first open:
#       System Settings > Privacy & Security > Open Anyway (the image's 安装与使用.txt walks through it).
#   DEVELOPER_ID="Developer ID Application: <name> (<team>)" NOTARY_PROFILE=<profile> tools/make_dmg.sh
#       Developer ID signature with the hardened runtime, notarized and stapled: opens like any downloaded app.
#       Needs the Apple Developer Program, that certificate in the keychain and a profile made once with
#       `xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>`.
#
# The app's code is not rebuilt, only re-signed: the script checks that the executable (signatures removed) and every
# resource are byte for byte those of the source app, and it never overwrites an existing image.
set -euo pipefail

step() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SRC="${APP_SRC:-$ROOT/apps/折声.app}"
# A fresh checkout has no apps/: take the Release build of the README's xcodebuild line instead.
[ -d "$APP_SRC" ] || APP_SRC="$ROOT/build/Build/Products/Release/折声.app"
[ -d "$APP_SRC" ] || fail "no app at $APP_SRC (build it first, or pass APP_SRC=<path to 折声.app>)"
DIST="${DIST:-$ROOT/dist}"
README="$ROOT/tools/dmg/安装与使用.txt"
ENTITLEMENTS="$ROOT/tools/dmg/entitlements.plist"
VOLNAME="折声"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP_SRC/Contents/Info.plist"; }
# The app keeps its product name inside the image whatever the source folder is called (a checkpoint copy, say).
APP_NAME="$(plist CFBundleName).app"
EXE="Contents/MacOS/$(plist CFBundleExecutable)"
VERSION="$(plist CFBundleShortVersionString)"
BUILD="$(plist CFBundleVersion)"
DMG="$DIST/${APP_NAME%.app}-$VERSION-build$BUILD.dmg"

if [ -n "${DEVELOPER_ID:-}" ]; then
    [ -n "${NOTARY_PROFILE:-}" ] || fail "DEVELOPER_ID needs NOTARY_PROFILE (xcrun notarytool store-credentials)"
    security find-identity -v -p codesigning | grep -qF "\"$DEVELOPER_ID\"" || fail "no identity \"$DEVELOPER_ID\" in the keychain"
fi
[ -e "$DMG" ] && fail "refuse overwrite: $DMG"

step "source: $APP_SRC (version $VERSION, build $BUILD)"
codesign --verify --deep --strict "$APP_SRC" || fail "the source app's signature is broken"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/eg2zh-dmg.XXXXXX")"
# Mount points on the startup disk: an image mounted onto a folder of an external disk can be refused
# ("attach failed - Permission denied"). hdiutil's create/attach options used here print a deprecation note on
# macOS 27 (diskutil image replaces them) but work.
MOUNTS="$(mktemp -d /tmp/eg2zh-mount.XXXXXX)"
MOUNT=""
cleanup() {
    set +e
    [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet -force
    rm -rf "$WORK"
    rmdir "$MOUNTS"/* "$MOUNTS" 2>/dev/null
}
trap cleanup EXIT
STAGE="$WORK/stage"
mkdir "$STAGE"

# Without extended attributes (quarantine, provenance, Finder info): the signature is in the bundle's files.
step "copy"
ditto --norsrc --noextattr --noqtn --noacl "$APP_SRC" "$STAGE/$APP_NAME"
APP="$STAGE/$APP_NAME"

# Xcode's "Sign to Run Locally" adds the debugger entitlement (get-task-allow); a re-signature without
# --entitlements has none. A Developer ID build gets the hardened runtime and the microphone entitlement it needs.
if [ -n "${DEVELOPER_ID:-}" ]; then
    step "sign: $DEVELOPER_ID, hardened runtime"
    codesign --force --sign "$DEVELOPER_ID" --options runtime --timestamp --entitlements "$ENTITLEMENTS" "$APP"
else
    step "sign: ad-hoc"
    codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
    fail "get-task-allow is still in the signature"
fi

step "same code and resources as the source app"
cp "$APP_SRC/$EXE" "$WORK/exe.source"
cp "$APP/$EXE" "$WORK/exe.packed"
codesign --remove-signature "$WORK/exe.source"
codesign --remove-signature "$WORK/exe.packed"
cmp "$WORK/exe.source" "$WORK/exe.packed" || fail "the executable differs from the source app's"
for file in Info.plist PkgInfo; do
    cmp "$APP_SRC/Contents/$file" "$APP/Contents/$file" || fail "$file differs from the source app's"
done
diff -r "$APP_SRC/Contents/Resources" "$APP/Contents/Resources" || fail "the resources differ from the source app's"
echo "executable, Info.plist and resources (model included) identical"

if [ -n "${DEVELOPER_ID:-}" ]; then
    # Notarize the app itself and staple it, so a copy dragged out of the image opens without a network check.
    step "notarize the app"
    ditto -c -k --keepParent "$APP" "$WORK/app.zip"
    xcrun notarytool submit "$WORK/app.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
fi

step "image"
ln -s /Applications "$STAGE/应用程序"
cp "$README" "$STAGE/"
xattr -w com.apple.TextEncoding 'utf-8;134217984' "$STAGE/$(basename "$README")"
mkdir -p "$DIST"
# Writable first, to give the volume the app's icon (.VolumeIcon.icns and the root folder's custom-icon flag),
# then compressed.
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -format UDRW "$WORK/rw.dmg"
MOUNT="$MOUNTS/rw"
mkdir "$MOUNT"
hdiutil attach "$WORK/rw.dmg" -readwrite -nobrowse -noautoopen -mountpoint "$MOUNT"
ICON="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist")"
cp "$APP/Contents/Resources/${ICON%.icns}.icns" "$MOUNT/.VolumeIcon.icns"
# FinderInfo of a folder: 8 bytes of window rectangle, then the flags; 0x0400 is kHasCustomIcon.
xattr -wx com.apple.FinderInfo "$(printf '%016d0400%044d' 0 0)" "$MOUNT"
rm -rf "$MOUNT/.fseventsd"
hdiutil detach "$MOUNT" -quiet
MOUNT=""
hdiutil convert "$WORK/rw.dmg" -format ULFO -o "$WORK/image.dmg"

if [ -n "${DEVELOPER_ID:-}" ]; then
    step "notarize the image"
    codesign --sign "$DEVELOPER_ID" --timestamp "$WORK/image.dmg"
    xcrun notarytool submit "$WORK/image.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$WORK/image.dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$WORK/image.dmg"
fi

step "check the image"
hdiutil verify "$WORK/image.dmg"
MOUNT="$MOUNTS/check"
mkdir "$MOUNT"
hdiutil attach "$WORK/image.dmg" -readonly -nobrowse -noautoopen -mountpoint "$MOUNT"
codesign --verify --deep --strict "$MOUNT/$APP_NAME"
[ "$(readlink "$MOUNT/应用程序")" = /Applications ] || fail "the Applications link is missing"
[ -f "$MOUNT/$(basename "$README")" ] || fail "the instructions are missing"
cmp -s "$MOUNT/.VolumeIcon.icns" "$APP/Contents/Resources/${ICON%.icns}.icns" || fail "the volume icon is missing"
xattr -px com.apple.FinderInfo "$MOUNT" | tr -d ' \n' | grep -q '^00000000000000000400' || fail "the volume's custom-icon flag is not set"
echo "app signature, Applications link, instructions and volume icon present"
hdiutil detach "$MOUNT" -quiet
MOUNT=""

mv "$WORK/image.dmg" "$DMG"
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
step "done"
ls -l "$DMG"
cat "$DMG.sha256"
