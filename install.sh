#!/bin/sh
set -eu

# CCminer Phone Farm Drop-in Installer (v2 manager layer)
# Usage:
#   unzip package.zip && cd package && sh install.sh
# Optional (recommended):
#   SSH_KEY_URL="https://your-controller/keys/farm.pub" sh install.sh

sudo apt-get -y update
sudo apt-get -y upgrade
sudo apt-get -y install libcurl4-openssl-dev libjansson-dev libomp-dev git screen nano jq wget ca-certificates

# libssl compatibility (best-effort)
if ! ldconfig -p 2>/dev/null | grep -q "libssl.so.1.1"; then
  sudo apt-get -y install libssl1.1 >/dev/null 2>&1 || true
fi

# SSH authorized_keys
mkdir -p "$HOME/.ssh"
chmod 0700 "$HOME/.ssh"
AUTH_KEYS="$HOME/.ssh/authorized_keys"
if [ ! -f "$AUTH_KEYS" ]; then
  if [ "${SSH_KEY_URL:-}" != "" ]; then
    echo "Fetching SSH key from: $SSH_KEY_URL"
    wget -qO "$AUTH_KEYS" "$SSH_KEY_URL"
  else
    cat << 'EOF' > "$AUTH_KEYS"
ssh-rsa AAAAB3Nz1yc2EAAAABJQAAAQBy6kORm+ECh2Vp1j3j+3F1Yg+EXNWY07HbP7dLZd/rqtdvPz8uxqWdgKBtyeM7R9AC1MW87zuCmss8GiSp2ZBIcpnr8kdMvYuI/qvEzwfY8pjvi2k3b/EwSP2R6/NqgbHctfVv1c7wL0M7myP9Zj7ZQPx+QV9DscogEEfc968RcV9jc+AgphUXC4blBf3MykzqjCP/SmaNhESr2F/mSxYiD8Eg7tTQ64phQ1oeOMzIzjWkW+P+vLGz+zk32RwmzX5V>
EOF
  fi
  chmod 0600 "$AUTH_KEYS"
fi

# CCminer dir
mkdir -p "$HOME/ccminer"
cd "$HOME/ccminer"

# Download latest release
GITHUB_RELEASE_JSON=$(curl --silent "https://api.github.com/repos/Oink70/CCminer-ARM-optimized/releases?per_page=1" | jq -c '[.[] | del (.body)]')
GITHUB_DOWNLOAD_URL=$(echo "$GITHUB_RELEASE_JSON" | jq -r ".[0].assets | .[] | .browser_download_url" | head -n 1)
GITHUB_DOWNLOAD_NAME=$(echo "$GITHUB_RELEASE_JSON" | jq -r ".[0].assets | .[] | .name" | head -n 1)

echo "Downloading latest release: $GITHUB_DOWNLOAD_NAME"
wget -q "$GITHUB_DOWNLOAD_URL" -O "$HOME/ccminer/$GITHUB_DOWNLOAD_NAME"

# Config.json
if [ -f "$HOME/ccminer/config.json" ]; then
  echo "config.json exists; keeping it."
else
  echo "Downloading default config.json..."
  wget -q "https://raw.githubusercontent.com/robsamdx64k/test/main/config.json" -O "$HOME/ccminer/config.json"
fi

# Install binary
if [ -f "$HOME/ccminer/ccminer" ]; then
  mv "$HOME/ccminer/ccminer" "$HOME/ccminer/ccminer_old" 2>/dev/null || true
fi
mv "$HOME/ccminer/$GITHUB_DOWNLOAD_NAME" "$HOME/ccminer/ccminer"
chmod +x "$HOME/ccminer/ccminer"

# Install manager layer bundled with this zip
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cp "$SCRIPT_DIR/manager.sh" "$HOME/ccminer/manager.sh"
chmod +x "$HOME/ccminer/manager.sh"
cp "$SCRIPT_DIR/manager.conf" "$HOME/ccminer/manager.conf"

# Backwards compatible start.sh
cat << 'EOF' > "$HOME/ccminer/start.sh"
#!/bin/sh
if [ -x "$HOME/ccminer/manager.sh" ]; then
  "$HOME/ccminer/manager.sh" start
  echo ""
  echo "Watchdog (recommended):"
  echo "  nohup $HOME/ccminer/manager.sh watchdog >/dev/null 2>&1 &"
else
  screen -S CCminer -X quit 1>/dev/null 2>&1
  screen -wipe 1>/dev/null 2>&1
  screen -dmS CCminer 1>/dev/null 2>&1
  screen -S CCminer -X stuff "$HOME/ccminer/ccminer -c $HOME/ccminer/config.json\n" 1>/dev/null 2>&1
fi
printf '\nMining started.\n'
printf '===============\n'
printf '\nManual:\n'
printf 'start: ~/ccminer/start.sh\n'
printf 'stop:  screen -X -S CCminer quit\n'
printf '\nmonitor mining: screen -x CCminer\n'
printf "exit monitor: 'CTRL-a' followed by 'd'\n\n"
EOF
chmod +x "$HOME/ccminer/start.sh"

echo "Setup complete."
echo "Edit config: nano $HOME/ccminer/config.json"
echo "Start:      cd $HOME/ccminer; ./start.sh"
echo "Watchdog:   nohup $HOME/ccminer/manager.sh watchdog >/dev/null 2>&1 &"
