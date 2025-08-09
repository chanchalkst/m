#!/bin/bash

VERSION=2.11

echo "MoneroOcean mining setup script v$VERSION."
echo "(please report issues to support@moneroocean.stream email with full output of this script with extra \"-x\" \"bash\" option)"
echo

if [ "$(id -u)" == "0" ]; then
  echo "WARNING: Generally it is not advised to run this script under root"
fi

WALLET=$1
EMAIL=$2 # optional worker/email tag

if [ -z "$WALLET" ]; then
  echo "Script usage:"
  echo "> setup_moneroocean_miner.sh <wallet address> [<your email address>]"
  echo "ERROR: Please specify your wallet address"
  exit 1
fi

WALLET_BASE=$(echo "$WALLET" | cut -f1 -d".")
if [ ${#WALLET_BASE} != 106 ] && [ ${#WALLET_BASE} != 95 ]; then
  echo "ERROR: Wrong wallet base address length (should be 106 or 95): ${#WALLET_BASE}"
  exit 1
fi

if [ -z "$HOME" ]; then
  echo "ERROR: Please define HOME environment variable to your home directory"
  exit 1
fi

if [ ! -d "$HOME" ]; then
  echo "ERROR: Please make sure HOME directory $HOME exists or set it yourself using:"
  echo '  export HOME=<dir>'
  exit 1
fi

if ! type curl >/dev/null 2>&1; then
  echo "ERROR: This script requires \"curl\" utility"
  exit 1
fi

CPU_THREADS=$(nproc)
EXP_MONERO_HASHRATE=$(( CPU_THREADS * 700 / 1000 ))
if [ -z "$EXP_MONERO_HASHRATE" ]; then
  echo "ERROR: Can't compute projected Monero CN hashrate"
  exit 1
fi

power2() {
  if ! type bc >/dev/null 2>&1; then
    if [ "$1" -gt "8192" ]; then echo "8192"
    elif [ "$1" -gt "4096" ]; then echo "4096"
    elif [ "$1" -gt "2048" ]; then echo "2048"
    elif [ "$1" -gt "1024" ]; then echo "1024"
    elif [ "$1" -gt "512" ]; then echo "512"
    elif [ "$1" -gt "256" ]; then echo "256"
    elif [ "$1" -gt "128" ]; then echo "128"
    elif [ "$1" -gt "64" ]; then echo "64"
    elif [ "$1" -gt "32" ]; then echo "32"
    elif [ "$1" -gt "16" ]; then echo "16"
    elif [ "$1" -gt "8" ]; then echo "8"
    elif [ "$1" -gt "4" ]; then echo "4"
    elif [ "$1" -gt "2" ]; then echo "2"
    else echo "1"
    fi
  else
    echo "x=l($1)/l(2); scale=0; 2^((x+0.5)/1)" | bc -l
  fi
}

PORT=$(( EXP_MONERO_HASHRATE * 30 ))
PORT=$(( PORT == 0 ? 1 : PORT ))
PORT=$(power2 $PORT)
PORT=$(( 10000 + PORT ))
if [ -z "$PORT" ]; then
  echo "ERROR: Can't compute port"
  exit 1
fi

if [ "$PORT" -lt "10001" ] || [ "$PORT" -gt "18192" ]; then
  echo "ERROR: Wrong computed port value: $PORT"
  exit 1
fi

echo "I will download, setup and run Monero CPU miner."
echo "Mining will happen to $WALLET wallet."
if [ ! -z "$EMAIL" ]; then
  echo "(and $EMAIL email as password to modify wallet options later at https://moneroocean.stream site)"
fi
echo

if ! sudo -n true 2>/dev/null; then
  echo "Mining in background will start from your $HOME/.profile file after reboot."
else
  echo "Mining in background will be performed using moneroocean_miner systemd service."
fi

echo
echo "This host has $CPU_THREADS CPU threads; projected Monero hashrate ~ $EXP_MONERO_HASHRATE KH/s."
echo

echo "Sleeping 15 seconds before continuing (Ctrl+C to cancel)..."
sleep 15
echo

echo "[*] Removing previous moneroocean miner (if any)"
if sudo -n true 2>/dev/null; then
  sudo systemctl stop moneroocean_miner.service
fi
killall -9 xmrig 2>/dev/null || true

echo "[*] Removing $HOME/moneroocean directory"
rm -rf "$HOME/moneroocean"

echo "[*] Downloading MoneroOcean advanced xmrig to /tmp/xmrig.tar.gz"
if ! curl -L --progress-bar "https://raw.githubusercontent.com/MoneroOcean/xmrig_setup/master/xmrig.tar.gz" -o /tmp/xmrig.tar.gz; then
  echo "ERROR: Can't download xmrig.tar.gz"
  exit 1
fi

echo "[*] Unpacking /tmp/xmrig.tar.gz to $HOME/moneroocean"
mkdir -p "$HOME/moneroocean"
if ! tar xf /tmp/xmrig.tar.gz -C "$HOME/moneroocean"; then
  echo "ERROR: Can't unpack xmrig.tar.gz"
  exit 1
fi
rm /tmp/xmrig.tar.gz

echo "[*] Checking xmrig works (not removed by antivirus)"
sed -i 's/"donate-level": *[^,]*,/"donate-level": 1,/' "$HOME/moneroocean/config.json"
"$HOME/moneroocean/xmrig" --help >/dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "WARNING: xmrig not functional, trying official release..."

  LATEST_XMRIG_RELEASE=$(curl -s https://github.com/xmrig/xmrig/releases/latest | grep -o '".*"' | sed 's/"//g')
  LATEST_XMRIG_LINUX_RELEASE="https://github.com$(curl -s "$LATEST_XMRIG_RELEASE" | grep xenial-x64.tar.gz\" | cut -d \" -f2)"

  echo "[*] Downloading official xmrig $LATEST_XMRIG_LINUX_RELEASE"
  if ! curl -L --progress-bar "$LATEST_XMRIG_LINUX_RELEASE" -o /tmp/xmrig.tar.gz; then
    echo "ERROR: Can't download official xmrig"
    exit 1
  fi

  echo "[*] Unpacking official xmrig"
  if ! tar xf /tmp/xmrig.tar.gz -C "$HOME/moneroocean" --strip=1; then
    echo "WARNING: Can't unpack official xmrig"
  fi
  rm /tmp/xmrig.tar.gz

  sed -i 's/"donate-level": *[^,]*,/"donate-level": 0,/' "$HOME/moneroocean/config.json"
  "$HOME/moneroocean/xmrig" --help >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo "ERROR: Official xmrig also not functional"
    exit 1
  fi
fi

echo "[*] Miner ready at $HOME/moneroocean/xmrig"

PASS=$(hostname | cut -f1 -d"." | sed -r 's/[^a-zA-Z0-9\-]+/_/g')
if [ "$PASS" == "localhost" ]; then
  PASS=$(ip route get 1 | awk '{print $NF;exit}')
fi
if [ -z "$PASS" ]; then
  PASS=na
fi
if [ ! -z "$EMAIL" ]; then
  PASS="$PASS:$EMAIL"
fi

# Set your pool URL here (your request):
POOL="pool.supportxmr.com:3333"

sed -i "s#\"url\": *\"[^\"]*\"#\"url\": \"$POOL\"#" "$HOME/moneroocean/config.json"
sed -i "s#\"user\": *\"[^\"]*\"#\"user\": \"$WALLET\"#" "$HOME/moneroocean/config.json"
sed -i "s#\"pass\": *\"[^\"]*\"#\"pass\": \"$PASS\"#" "$HOME/moneroocean/config.json"
sed -i 's/"max-cpu-usage": *[^,]*,/"max-cpu-usage": 100,/' "$HOME/moneroocean/config.json"
sed -i "s#\"log-file\": *null,#\"log-file\": \"$HOME/moneroocean/xmrig.log\",#" "$HOME/moneroocean/config.json"
sed -i 's/"syslog": *[^,]*,/"syslog": true,/' "$HOME/moneroocean/config.json"

cp "$HOME/moneroocean/config.json" "$HOME/moneroocean/config_background.json"
sed -i 's/"background": *false,/"background": true,/' "$HOME/moneroocean/config_background.json"

echo "[*] Creating $HOME/moneroocean/miner.sh script"
cat >"$HOME/moneroocean/miner.sh" <<'EOL'
#!/bin/bash
if ! pidof xmrig >/dev/null; then
  nice "$HOME/moneroocean/xmrig" "$@"
else
  echo "Monero miner is already running in the background. Refusing to run another one."
  echo "Run \"killall xmrig\" or \"sudo killall xmrig\" if you want to remove background miner first."
fi
EOL

chmod +x "$HOME/moneroocean/miner.sh"

if ! sudo -n true 2>/dev/null; then
  if ! grep -q "$HOME/moneroocean/miner.sh" "$HOME/.profile"; then
    echo "[*] Adding miner script to $HOME/.profile"
    echo "$HOME/moneroocean/miner.sh --config=$HOME/moneroocean/config_background.json >/dev/null 2>&1" >>"$HOME/.profile"
  fi
  echo "[*] Running miner in background"
  /bin/bash "$HOME/moneroocean/miner.sh" --config="$HOME/moneroocean/config_background.json"
