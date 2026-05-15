#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$HOME/.ai-spending"

echo "==> Creating project venv..."
VENV="$REPO/.venv"
if [ ! -d "$VENV" ]; then
  python3 -m venv "$VENV"
fi
VENV_PY="$VENV/bin/python3"

echo "==> Installing Python proxy dependencies into venv..."
"$VENV_PY" -m pip install -q --upgrade pip
"$VENV_PY" -m pip install -q -r "$REPO/requirements.txt"

echo "==> Building native menu-bar app..."
cd "$REPO"
xcodegen generate --quiet
xcodebuild -project SpendTracker.xcodeproj \
  -scheme SpendTracker \
  -configuration Release \
  -derivedDataPath .build \
  build 2>&1 | grep -E "error:|warning:|BUILD" || true

APP_SRC="$REPO/.build/Build/Products/Release/SpendTracker.app"
APP_DST="/Applications/SpendTracker.app"
if [ -d "$APP_SRC" ]; then
  echo "==> Installing SpendTracker.app → $APP_DST"
  rm -rf "$APP_DST"
  cp -R "$APP_SRC" "$APP_DST"
else
  echo "WARNING: App not found at $APP_SRC, skipping install."
fi

echo "==> Injecting shell environment variables..."
SHELL_RC="$HOME/.zshrc"
[[ "$SHELL" == *bash* ]] && SHELL_RC="$HOME/.bashrc"

add_export() {
  grep -qF "$1" "$SHELL_RC" 2>/dev/null || echo "export $1" >> "$SHELL_RC"
}
add_export "ANTHROPIC_BASE_URL=http://localhost:7778/anthropic"
add_export "OPENAI_BASE_URL=http://localhost:7778/openai"
add_export "MISTRAL_SERVER_URL=http://localhost:7778/mistral"
add_export "GOOGLE_API_BASE_URL=http://localhost:7778/gemini"
add_export "HF_BASE_URL=http://localhost:7778/huggingface"

echo "==> Registering proxy daemon (launchd)..."
PLIST="$HOME/Library/LaunchAgents/com.amastro.ai-spend-proxy.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>         <string>com.amastro.ai-spend-proxy</string>
  <key>ProgramArguments</key>
  <array>
    <string>$VENV_PY</string>
    <string>$REPO/proxy/server.py</string>
  </array>
  <key>RunAtLoad</key>     <true/>
  <key>KeepAlive</key>     <true/>
  <key>StandardOutPath</key>  <string>$STATE_DIR/proxy.log</string>
  <key>StandardErrorPath</key><string>$STATE_DIR/proxy.log</string>
</dict>
</plist>
PLIST_EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"

echo ""
echo "✓ Done!"
echo "  • Proxy daemon registered and running on :7778"
echo "  • SpendTracker.app installed to /Applications"
echo "  • Shell env vars added to $SHELL_RC"
echo ""
echo "  Open /Applications/SpendTracker.app (or it will auto-launch at login)."
echo "  Reload your shell: source $SHELL_RC"
