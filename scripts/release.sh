#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Spit — Release script
# Usage: ./scripts/release.sh [version] [build]
# Example: ./scripts/release.sh 1.1.0 2
#
# What it does:
#   1. Updates version in Info.plist
#   2. Builds Release archive (xcodebuild)
#   3. Exports .app and creates signed .dmg
#   4. Uploads DMG to GitHub as new release
#   5. Updates latest.json on the site
#   6. Updates download URL in spit-landing.html
#   7. Commits + pushes (Cloudflare Pages auto-deploys)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="$REPO_ROOT/VoiceFlow.xcodeproj"
SCHEME="VoiceFlow"
PLIST="$REPO_ROOT/VoiceFlow/Resources/Info.plist"
LANDING="$REPO_ROOT/spit-landing.html"
LATEST_JSON="$REPO_ROOT/latest.json"
ARCHIVES_DIR="$REPO_ROOT/.build/archives"
EXPORTS_DIR="$REPO_ROOT/.build/export"
DMG_DIR="$REPO_ROOT/.build/dmg"

# ── Version args ──────────────────────────────────────────────────────────────
VERSION="${1:-}"
BUILD="${2:-}"

if [ -z "$VERSION" ]; then
  CURRENT_VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST")
  read -p "Version [$CURRENT_VER]: " VERSION
  VERSION="${VERSION:-$CURRENT_VER}"
fi

if [ -z "$BUILD" ]; then
  CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST")
  NEXT_BUILD=$((CURRENT_BUILD + 1))
  read -p "Build number [$NEXT_BUILD]: " BUILD
  BUILD="${BUILD:-$NEXT_BUILD}"
fi

TAG="v$VERSION"
DMG_NAME="Spit.dmg"
ARCHIVE_PATH="$ARCHIVES_DIR/Spit-$VERSION.xcarchive"

echo ""
echo "▶ Releasing Spit $VERSION (build $BUILD) → $TAG"
echo ""

# ── Preflight ─────────────────────────────────────────────────────────────────
command -v gh >/dev/null 2>&1 || { echo "❌ gh CLI not found. Install: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "❌ Not logged in to gh. Run: gh auth login"; exit 1; }

# Check tag doesn't already exist
if gh release view "$TAG" --repo rafaellopes/spit >/dev/null 2>&1; then
  echo "❌ Release $TAG already exists on GitHub. Bump the version."
  exit 1
fi

# ── Kill running Spit ─────────────────────────────────────────────────────────
echo "⏹  Stopping Spit..."
kill $(pgrep Spit) 2>/dev/null || true

# ── Update Info.plist ─────────────────────────────────────────────────────────
echo "📝 Updating version → $VERSION ($BUILD)..."
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $BUILD" "$PLIST"

# ── Build Release archive ──────────────────────────────────────────────────────
mkdir -p "$ARCHIVES_DIR"
echo "🔨 Building Release archive (this takes a while)..."
xcodebuild archive \
  -project "$PROJ" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_IDENTITY="Apple Development" \
  2>&1 | grep -E "error:|warning:|BUILD|Compiling|Linking|Archive" | tail -20

if [ ! -d "$ARCHIVE_PATH" ]; then
  echo "❌ Archive failed — check build output above"
  exit 1
fi
echo "✅ Archive created"

# ── Export .app ───────────────────────────────────────────────────────────────
mkdir -p "$EXPORTS_DIR"
EXPORT_PLIST=$(mktemp /tmp/spit-export-XXXXXX.plist)
cat > "$EXPORT_PLIST" << 'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>development</string>
  <key>teamID</key>
  <string>R6VWLH887N</string>
</dict>
</plist>
PLIST_EOF

echo "📦 Exporting .app..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORTS_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  2>&1 | grep -E "error:|Export|Packaging" | tail -10
rm -f "$EXPORT_PLIST"

APP_PATH=$(find "$EXPORTS_DIR" -name "*.app" -maxdepth 2 | head -1)
if [ -z "$APP_PATH" ]; then
  echo "❌ Export failed — .app not found"
  exit 1
fi
echo "✅ Exported: $APP_PATH"

# ── Create DMG ────────────────────────────────────────────────────────────────
mkdir -p "$DMG_DIR"
FINAL_DMG="$DMG_DIR/$DMG_NAME"
TMP_DMG="$DMG_DIR/tmp_$DMG_NAME"
rm -f "$FINAL_DMG" "$TMP_DMG"

echo "💿 Creating DMG..."
# Temp writable DMG
hdiutil create -size 200m -volname "Spit" -srcfolder "$APP_PATH" \
  -ov -format UDRW "$TMP_DMG" >/dev/null

# Mount, add Applications symlink
MOUNT_DIR=$(hdiutil attach "$TMP_DMG" | grep Volumes | awk '{print $3}')
ln -s /Applications "$MOUNT_DIR/Applications" 2>/dev/null || true
hdiutil detach "$MOUNT_DIR" >/dev/null

# Convert to compressed read-only
hdiutil convert "$TMP_DMG" -format UDZO -o "$FINAL_DMG" >/dev/null
rm -f "$TMP_DMG"
echo "✅ DMG created: $FINAL_DMG ($(du -sh "$FINAL_DMG" | cut -f1))"

# ── Prompt for release notes ──────────────────────────────────────────────────
echo ""
echo "📝 Enter release notes (empty line to finish):"
NOTES=""
while IFS= read -r line; do
  [ -z "$line" ] && break
  NOTES="$NOTES$line\n"
done
[ -z "$NOTES" ] && NOTES="Spit $VERSION — bug fixes and improvements.\n"

# ── Upload to GitHub ──────────────────────────────────────────────────────────
echo ""
echo "🚀 Uploading to GitHub releases..."
gh release create "$TAG" \
  --repo rafaellopes/spit \
  --title "Spit $VERSION" \
  --notes "$(printf "$NOTES")" \
  "$FINAL_DMG"
echo "✅ GitHub release $TAG published"

# ── Generate latest.json ──────────────────────────────────────────────────────
DOWNLOAD_URL="https://github.com/rafaellopes/spit/releases/download/$TAG/$DMG_NAME"
RELEASE_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > "$LATEST_JSON" << JSON_EOF
{
  "version": "$VERSION",
  "build": $BUILD,
  "date": "$RELEASE_DATE",
  "url": "$DOWNLOAD_URL",
  "notes": "$(printf "$NOTES" | tr '\n' ' ' | sed 's/  */ /g')",
  "min_os": "13.0"
}
JSON_EOF
echo "✅ latest.json updated"

# ── Update download URL in landing page ──────────────────────────────────────
echo "🌐 Updating spit-landing.html..."
sed -i '' "s|releases/download/v[0-9][0-9.]*/Spit\.dmg|releases/download/$TAG/Spit.dmg|g" "$LANDING"
echo "✅ Landing page updated"

# ── Commit + push (triggers Cloudflare Pages deploy) ──────────────────────────
echo "🔄 Committing and pushing..."
cd "$REPO_ROOT"
git add "$PLIST" "$LANDING" "$LATEST_JSON"
git commit -m "chore: release $VERSION (build $BUILD)"
git push origin main
echo "✅ Pushed — Cloudflare Pages will deploy in ~30s"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Spit $VERSION released!"
echo ""
echo "  GitHub:   https://github.com/rafaellopes/spit/releases/tag/$TAG"
echo "  Download: $DOWNLOAD_URL"
echo "  Site:     https://getspit.app (deploying now)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
