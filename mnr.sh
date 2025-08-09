#!/bin/bash

VERSION=2.11

echo "MoneroOcean mining setup script v$VERSION."
echo

if [ "$(id -u)" == "0" ]; then
  echo "WARNING: Running as root is not recommended."
fi

# Arguments
WALLET=$1
WORKER=$2

if [ -z "$WALLET" ]; then
  echo "Usage: $0 <wallet_address> [worker_name]"
  echo "ERROR: Please specify your wallet address"
  exit 1
fi

WALLET_BASE=$(echo "$WALLET" | cut -f1 -d".")
if [ ${#WALLET_BASE} != 106 -a ${#WALLET_BASE} != 95 ]; then
  echo "ERROR: Wallet address length looks wrong (should be 106 or 95 chars)"
  exit 1
fi

if [ -z "$HOME" ] || [ ! -d "$HOME" ]; then
  echo "ERROR: HOME directory not set or does not exist."
  exit 1
fi

if ! type curl >/dev/null 2>&1; then
  echo "ERROR: curl utility is required."
  exit 1
fi

POOL_URL="pool.supportxmr.com:3333"

CPU_THREADS=$(nproc)
EXP_HASHRATE=$(( CPU_THREADS * 700 / 1000 ))

echo "Mining to pool: $POOL_URL"
echo "Wallet: $WALLET"
if [ ! -z "$WORKER" ]; then
  echo "Worker name: $WORKER"
fi
echo "CPU threads: $CPU_THREADS (estimated hashrate: ${EXP_HASHRATE}KH/s)"
echo

# Stop any previous miner and clean up
killall -9 xmrig 2>/dev/null
rm -rf "$HOME/moneroocean"

# Download miner
echo "[*] Downloading miner..."
curl -L --progress-bar "https://raw.githubusercontent.com/MoneroOcean/xmrig_setup/master/xmrig.tar.gz" -o /tmp/xmrig.tar.gz || {
  echo "ERROR: Download failed"; exit 1;
}

mkdir -p "$HOME/moneroocean"
tar xf /tmp/xmrig.tar.gz -C "$HOME/moneroocean" || {
  echo "ERROR: Extract failed"; exit 1;
}
rm /tmp/xmrig.tar.gz

# Set user with worker if provided
if [ ! -z "$WORKER" ]; then
  USER="$WALLET.$WORKER"
else
  USER="$WALLET"
fi

# Setup config
PASS=$(hostname | cut -f1 -d"." | sed -r 's/[^a-zA-Z0-9\-]+/_/g')
if [ "$PASS" == "localhost" ]; then
  PASS=$(ip route get 1 | awk '{print $NF;exit}')
fi
if [ -z "$PASS" ]; then
  PASS=na
fi

sed -i 's#"url": *"[^"]*",#"url": "'"$POOL_URL"'",#' "$HOME/moneroocean/config.json"
sed -i 's/"user": *"[^"]*",/"user": "'"$USER"'",/' "$HOME/moneroocean/config.json"
sed -i 's/"pass": *"[^"]*",/"pass": "'"$PASS"'",/' "$HOME/moneroocean/config.json"
sed -i 's/"max-cpu-usage": *[^,]*,/"max-cpu-usage": 100,/' "$HOME/moneroocean/config.json"

# Create start script
cat > "$HOME/moneroocean/miner.sh" <<EOL
#!/bin/bash
if ! pidof xmrig >/dev/null; then
  nice $HOME/moneroocean/xmrig \$*
else
  echo "Miner already running."
fi
EOL
chmod +x "$HOME/moneroocean/miner.sh"

# Run miner in background
echo "[*] Starting miner in background..."
"$HOME/moneroocean/miner.sh" --config="$HOME/moneroocean/config.json" >/dev/null 2>&1 &

echo "[*] Setup complete. Use $HOME/moneroocean/miner.sh to start miner manually."
