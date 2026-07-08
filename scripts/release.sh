#!/usr/bin/env bash
# scripts/release.sh — Spit release pipeline
#
# Uso:
#   ./scripts/release.sh                    # incrementa build, mantém versão
#   ./scripts/release.sh --version 2.1      # nova versão + incrementa build
#   ./scripts/release.sh --build 15         # build explícito
#   ./scripts/release.sh --dry-run          # tudo excepto push e GitHub release
#
# Pré-requisitos (primeira vez):
#   1. brew install create-dmg
#   2. xcrun notarytool store-credentials "spit-notary" \
#        --apple-id "rafa@rafamail.com" --team-id "R6VWLH887N" --password "<app-specific-pwd>"
#   3. Chave privada Sparkle em ~/.config/spit/sparkle_ed25519_private.pem

set -euo pipefail

# ── Configuração ────────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO_ROOT/VoiceFlow.xcodeproj"
SCHEME="VoiceFlow"
SIGNING_IDENTITY="Developer ID Application: Rafael Lopes (R6VWLH887N)"
TEAM_ID="R6VWLH887N"
NOTARY_PROFILE="spit-notary"
PRIVATE_KEY="$HOME/.config/spit/sparkle_private_raw.b64"
APPCAST="$REPO_ROOT/appcast.xml"
LATEST_JSON="$REPO_ROOT/latest.json"
INFO_PLIST="$REPO_ROOT/VoiceFlow/Resources/Info.plist"
GITHUB_REPO="Draxo-io/spit"

# ── Parse args ──────────────────────────────────────────────────────────────────

DRY_RUN=false
NEW_VERSION=""
NEW_BUILD=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)   DRY_RUN=true; shift ;;
        --version)   NEW_VERSION="$2"; shift 2 ;;
        --build)     NEW_BUILD="$2"; shift 2 ;;
        *) echo "Argumento desconhecido: $1"; exit 1 ;;
    esac
done

# ── Helpers ─────────────────────────────────────────────────────────────────────

log()  { echo "▸ $*"; }
ok()   { echo "✅ $*"; }
fail() { echo "❌ $*" >&2; exit 1; }

# ── Verificar pré-requisitos ────────────────────────────────────────────────────

log "A verificar pré-requisitos…"

[[ -f "$PRIVATE_KEY" ]] || fail "Chave privada Sparkle não encontrada: $PRIVATE_KEY"

SIGN_UPDATE=$(find ~/Library/Developer/Xcode/DerivedData -path "*/artifacts/sparkle/Sparkle/bin/sign_update" 2>/dev/null | head -1)
[[ -n "$SIGN_UPDATE" ]] || fail "sign_update não encontrado. Corre: xcodebuild -project VoiceFlow.xcodeproj -resolvePackageDependencies"

command -v gh >/dev/null || fail "gh CLI não instalado: brew install gh"
command -v create-dmg >/dev/null || fail "create-dmg não instalado: brew install create-dmg"

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" &>/dev/null || \
    fail "Perfil de notarização '$NOTARY_PROFILE' inválido.
Executa:
  xcrun notarytool store-credentials '$NOTARY_PROFILE' \\
    --apple-id rafa@rafamail.com \\
    --team-id $TEAM_ID \\
    --password <app-specific-password>"

ok "Pré-requisitos OK"

# ── Ler versão atual ────────────────────────────────────────────────────────────

CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$INFO_PLIST")
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$INFO_PLIST")

VERSION="${NEW_VERSION:-$CURRENT_VERSION}"
BUILD="${NEW_BUILD:-$((CURRENT_BUILD + 1))}"

log "Versão: $CURRENT_VERSION (build $CURRENT_BUILD) → $VERSION (build $BUILD)"

# ── Actualizar Info.plist ───────────────────────────────────────────────────────

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$INFO_PLIST"
ok "Info.plist actualizado: $VERSION ($BUILD)"

# ── Build (Archive) ─────────────────────────────────────────────────────────────

ARCHIVE_PATH="/tmp/Spit-$VERSION-$BUILD.xcarchive"
[[ -d "$ARCHIVE_PATH" ]] && rm -rf "$ARCHIVE_PATH"

log "A compilar em Release (pode demorar 2-3 min)…"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    archive \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    ENABLE_HARDENED_RUNTIME=YES \
    2>&1 | grep -E "^(error:|Build|Archive|FAILED|SUCCEEDED)" || true

[[ -d "$ARCHIVE_PATH" ]] || fail "Archive falhou"
ok "Archive criado"

# ── Export .app ─────────────────────────────────────────────────────────────────

EXPORT_PATH="/tmp/Spit-export-$BUILD"
[[ -d "$EXPORT_PATH" ]] && rm -rf "$EXPORT_PATH"

EXPORT_OPTIONS="/tmp/spit-export-options.plist"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>$SIGNING_IDENTITY</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    2>&1 | grep -E "^(error:|Export|FAILED|SUCCEEDED)" || true

APP_PATH="$EXPORT_PATH/Spit.app"
[[ -d "$APP_PATH" ]] || fail "Export falhou — Spit.app não encontrado em $EXPORT_PATH"
ok "App exportada: $APP_PATH"

# ── Criar DMG ───────────────────────────────────────────────────────────────────

DMG_NAME="Spit-$VERSION.dmg"
DMG_PATH="/tmp/$DMG_NAME"
[[ -f "$DMG_PATH" ]] && rm "$DMG_PATH"

log "A criar DMG…"
create-dmg \
    --volname "Spit $VERSION" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "Spit.app" 175 190 \
    --hide-extension "Spit.app" \
    --app-drop-link 425 190 \
    "$DMG_PATH" \
    "$APP_PATH" 2>&1 | tail -2

[[ -f "$DMG_PATH" ]] || fail "create-dmg falhou"
ok "DMG criado: $(du -sh "$DMG_PATH" | cut -f1)"

# ── Notarizar ───────────────────────────────────────────────────────────────────

log "A submeter para notarização (1-5 min)…"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    2>&1 | grep -E "status:|id:|createdDate"

log "A staple o ticket de notarização…"
xcrun stapler staple "$DMG_PATH"
ok "Notarizado e stappled"

# ── Assinar com Sparkle ─────────────────────────────────────────────────────────

log "A assinar DMG com chave EdDSA…"

# sign_update emite uma linha XML; extraímos só o valor da assinatura
SIGN_OUTPUT=$("$SIGN_UPDATE" --ed-key-file "$PRIVATE_KEY" "$DMG_PATH" 2>&1)
SIGNATURE=$(echo "$SIGN_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | sed 's/sparkle:edSignature="\([^"]*\)"/\1/')
DMG_SIZE=$(stat -f%z "$DMG_PATH")

[[ -n "$SIGNATURE" ]] || fail "Falhou a gerar assinatura EdDSA. Output:\n$SIGN_OUTPUT"
ok "Assinatura EdDSA gerada"

# ── Atualizar appcast.xml ───────────────────────────────────────────────────────

RELEASE_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
GITHUB_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$DMG_NAME"

log "A actualizar appcast.xml…"
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Spit</title>
        <link>https://getspit.app</link>
        <description>Spit release history</description>
        <language>en</language>
        <item>
            <title>Spit $VERSION</title>
            <pubDate>$RELEASE_DATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <description><![CDATA[
                <p>Changelog completo em <a href="https://github.com/$GITHUB_REPO/releases/tag/v$VERSION">GitHub</a>.</p>
            ]]></description>
            <enclosure
                url="$GITHUB_URL"
                sparkle:edSignature="$SIGNATURE"
                length="$DMG_SIZE"
                type="application/octet-stream"/>
        </item>
    </channel>
</rss>
XML

ok "appcast.xml actualizado"

# ── Atualizar latest.json ───────────────────────────────────────────────────────

TODAY=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
cat > "$LATEST_JSON" <<JSON
{
  "version": "$VERSION",
  "build": $BUILD,
  "date": "$TODAY",
  "url": "$GITHUB_URL",
  "notes": "Changelog: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION",
  "min_os": "14.0"
}
JSON

ok "latest.json actualizado"

# ── Dry-run: parar aqui ─────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "── DRY RUN completo ──────────────────────────────────────────────"
    echo "   DMG:        $DMG_PATH"
    echo "   Assinatura: ${SIGNATURE:0:30}…"
    echo "   (GitHub release e git push não executados)"
    exit 0
fi

# ── Criar GitHub Release e fazer upload do DMG ──────────────────────────────────

TAG="v$VERSION"
log "A criar release $TAG no GitHub…"

gh release create "$TAG" "$DMG_PATH" \
    --repo "$GITHUB_REPO" \
    --title "Spit $VERSION" \
    --notes "Vê o [CHANGELOG](https://github.com/$GITHUB_REPO/blob/main/CHANGELOG.md) para detalhes desta versão." \
    --latest

ok "GitHub release criada"

# ── Commit e push ───────────────────────────────────────────────────────────────

log "A commitar e fazer push…"
git -C "$REPO_ROOT" add "$APPCAST" "$LATEST_JSON" "$INFO_PLIST"
git -C "$REPO_ROOT" commit -m "chore: release Spit $VERSION (build $BUILD)"
git -C "$REPO_ROOT" push origin main

ok "Push concluído"

echo ""
echo "🚀 Spit $VERSION (build $BUILD) publicado!"
echo "   https://github.com/$GITHUB_REPO/releases/tag/$TAG"
echo "   Os utilizadores serão notificados em até 24h via Sparkle."
