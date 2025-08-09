#!/bin/bash

VERSION=1.5

echo "SupportXMR mining setup script v$VERSION."
echo

if [ "$(id -u)" == "0" ]; then
  echo "WARNING: Generally it is not advised to run this script under root"
fi

# Args:
# $1 = wallet[.worker]
WALLET_INPUT=$1

if [ -z "$WALLET_INPUT" ]; then
  echo "Usage:"
  echo "  ./setup_supportxmr_miner.sh <wallet[.worker]>"
  echo "Example:"
  echo "  ./setup_supportxmr_miner.sh 48...Wallet.Worker1"
  exit 1
fi

# Extract wallet and optional worker
WALLET=$(echo "$WALLET_INPUT" | cut -d"." -f1)
WORKER=$(echo "$WALLET_INPUT" | cut -s -d"." -f2)

if [ ${#WALLET} != 106 ] && [ ${#WALLET} != 95 ]; then
  echo "ERROR: Wallet length should be 106 or 95 characters."
  exit 1
fi

if [ -z "$WORKER" ]; then
  WORKER=$(hostname | sed -r 's/[^a-zA-Z0-9\-]+/_/g')
fi

# Calculate ~75% of CPU threads
CPU_THREADS=$(nproc)
CPU_USE=$(echo "$CPU_THREADS * 0.75" | bc | awk '{print int($1)}')
if [ "$CPU_USE" -lt 1 ]; then CPU_USE=1; fi

echo "Detected $CPU_THREADS CPU threads."
echo "Using $CPU_USE threads (~75% CPU usage)"
sleep 2

echo "[*] Removing previous miner..."
if sudo -n true 2>/dev/null; then
  sudo systemctl stop xmrig_miner.service
fi
killall -9 xmrig 2>/dev/null
rm -rf "$HOME/xmrig"

echo "[*] Downloading latest XMRig..."
LATEST_XMRIG_RELEASE=$(curl -s https://api.github.com/repos/xmrig/xmrig/releases/latest \
  | grep "browser_download_url" \
  | grep "linux-x64.tar.gz" \
  | cut -d '"' -f 4)

if ! curl -L --progress-bar "$LATEST_XMRIG_RELEASE" -o /tmp/xmrig.tar.gz; then
  echo "ERROR: Can't download xmrig"
  exit 1
fi

mkdir -p "$HOME/xmrig"
if ! tar xf /tmp/xmrig.tar.gz -C "$HOME/xmrig" --strip=1; then
  echo "ERROR: Can't unpack xmrig"
  exit 1
fi
rm /tmp/xmrig.tar.gz

"$HOME/xmrig/xmrig" --help >/dev/null || {
  echo "ERROR: xmrig binary not functional"
  exit 1
}

cat > "$HOME/xmrig/config.json" <<EOL
{
    "api": { "id": null, "worker-id": null },
    "autosave": true,
    "background": false,
    "colors": true,
    "randomx": {},
    "cpu": { "enabled": true, "huge-pages": true, "hw-aes": null, "priority": null, "asm": true, "max-threads-hint": $CPU_USE },
    "opencl": { "enabled": false },
    "cuda": { "enabled": false },
    "pools": [
        {
            "url": "pool.supportxmr.com:3333",
            "user": "$WALLET.$WORKER",
            "pass": "x",
            "keepalive": true,
            "tls": false
        }
    ]
}
EOL

cp "$HOME/xmrig/config.json" "$HOME/xmrig/config_background.json"
sed -i 's/"background": false/"background": true/' "$HOME/xmrig/config_background.json"

echo "[*] Creating $HOME/xmrig/miner.sh"
cat > "$HOME/xmrig/miner.sh" <<EOL
#!/bin/bash
if ! pidof xmrig >/dev/null; then
  nice $HOME/xmrig/xmrig \$*
else
  echo "Miner is already running."
fi
EOL
chmod +x "$HOME/xmrig/miner.sh"

if ! sudo -n true 2>/dev/null; then
  if ! grep xmrig/miner.sh "$HOME/.profile" >/dev/null; then
    echo "[*] Adding miner to .profile"
    echo "$HOME/xmrig/miner.sh --config=$HOME/xmrig/config_background.json >/dev/null 2>&1" >> "$HOME/.profile"
  fi
  echo "[*] Running miner in background"
  "$HOME/xmrig/miner.sh" --config="$HOME/xmrig/config_background.json" >/dev/null 2>&1
else
  echo "[*] Creating xmrig_miner systemd service"
  cat > /tmp/xmrig_miner.service <<EOL
[Unit]
Description=XMRig Monero miner service

[Service]
ExecStart=$HOME/xmrig/xmrig --config=$HOME/xmrig/config_background.json
Restart=always
Nice=10
CPUWeight=1

[Install]
WantedBy=multi-user.target
EOL
  sudo mv /tmp/xmrig_miner.service /etc/systemd/system/xmrig_miner.service
  sudo systemctl daemon-reload
  sudo systemctl enable xmrig_miner.service
  sudo systemctl start xmrig_miner.service
  echo "To see logs: sudo journalctl -u xmrig_miner -f"
fi

echo
echo "[*] Setup complete."
echo "Mining to: $WALLET"
echo "Worker: $WORKER"
echo "CPU threads used: $CPU_USE (approx. 75%)"
