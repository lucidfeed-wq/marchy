#!/bin/zsh
# Build Marchy.app and Marchy-<version>.dmg from this repository.
#
#   scripts/build-app.sh                 # version from VERSION, ad-hoc signed
#   scripts/build-app.sh 0.2.0           # explicit version
#
# Signing: set MARCHY_SIGN_IDENTITY="Developer ID Application: …" to sign for distribution, and
# MARCHY_NOTARY_PROFILE=<notarytool keychain profile> to notarize the DMG. Without them the app is
# ad-hoc signed: macOS asks people to approve it once (System Settings > Privacy & Security).
set -euo pipefail
ROOT=${0:A:h:h}
VERSION=${1:-$(<$ROOT/VERSION)}
REPO=${MARCHY_REPOSITORY:-lucidfeed-wq/marchy}
OUT=$ROOT/build
APP=$OUT/Marchy.app
print "==> Marchy $VERSION"

rm -rf $OUT && mkdir -p $APP/Contents/{MacOS,Resources}

print "==> compiling"
( cd $ROOT/app && swift build -c release --arch arm64 )
cp $ROOT/app/.build/arm64-apple-macosx/release/Marchy $APP/Contents/MacOS/Marchy
cp $ROOT/app/Resources/AppIcon.icns $ROOT/app/Resources/askpass.sh $APP/Contents/Resources/

print "==> bundling the omarchy-mac build (payload)"
# Every tracked or new-but-not-ignored file, minus the app's own sources and CI files.
PAY=$APP/Contents/Resources/payload
mkdir -p $PAY
( cd $ROOT && git ls-files -co --exclude-standard | grep -v -E '^(app/|build/|scripts/make-icon|\.github/|packaging/)' ) \
  | rsync -a --files-from=- $ROOT/ $PAY/
print "   $(find $PAY -type f | wc -l | tr -d ' ') files"

cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Marchy</string>
  <key>CFBundleDisplayName</key><string>Marchy</string>
  <key>CFBundleIdentifier</key><string>io.github.lucidfeed-wq.marchy</string>
  <key>CFBundleExecutable</key><string>Marchy</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT licensed. Unofficial; not affiliated with Omarchy or Basecamp.</string>
  <key>MarchyRepository</key><string>$REPO</string>
</dict></plist>
EOF

print "==> signing"
if [[ -n ${MARCHY_SIGN_IDENTITY:-} ]]; then
  codesign --force --deep --options runtime --timestamp --sign "$MARCHY_SIGN_IDENTITY" $APP
else
  codesign --force --deep --sign - $APP
fi
codesign --verify --deep --strict $APP

print "==> disk image"
STAGE=$OUT/dmg
mkdir -p $STAGE && cp -R $APP $STAGE/ && ln -s /Applications $STAGE/Applications
DMG=$OUT/Marchy-$VERSION.dmg
hdiutil create -quiet -volname "Marchy $VERSION" -srcfolder $STAGE -ov -format UDZO $DMG
rm -rf $STAGE
if [[ -n ${MARCHY_SIGN_IDENTITY:-} ]]; then codesign --sign "$MARCHY_SIGN_IDENTITY" --timestamp $DMG; fi
if [[ -n ${MARCHY_NOTARY_PROFILE:-} ]]; then
  xcrun notarytool submit $DMG --keychain-profile "$MARCHY_NOTARY_PROFILE" --wait
  xcrun stapler staple $DMG
fi
shasum -a 256 $DMG | tee $DMG.sha256
print "==> $DMG"
