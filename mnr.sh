#!/bin/bash

VERSION=2.11

echo "MoneroOcean mining setup script v$VERSION."
echo "(please report issues to support@moneroocean.stream email with full output of this script with extra \"-x\" \"bash\" option)"
echo

if [ "$(id -u)" == "0" ]; then
  echo "WARNING: Generally it is not advised to run this script under root"
fi

# command line arguments
WALLET=$1
WORKER_NAME=$2  # new second argument for worker name (optional)

if [ -z "$WALLET" ]; then
  echo "Script usage:"
  echo "> setup_moneroocean_miner.sh <wallet address> [<worker name>]"
  echo "ERROR: Please specify your wallet address"
  exit 1
fi

if [ -z "$WORKER_NAME" ]; then
  WORKER_NAME="worker01"
fi

WALLET_BASE=`echo $WALLET | cut -f1 -d"."`
if [ ${#WALLET_BASE} != 106 -a ${#WALLET_BASE} != 95 ]; then
  echo "ERROR: Wrong wallet base address length (should be 106 or 95): ${#WALLET_BASE}"
  exit 1
fi

if [ -z "$HOME" ]; then
  echo "ERROR: Please define HOME environment variable to your home directory"
  exit 1
fi

if [ ! -d "$HOME" ]; then
  echo "ERROR: Please make sure HOME directory $HOME exists or set it yourself using this command:"
  echo '  export HOME=<dir>'
  exit 1
fi

if ! type curl >/dev/null; then
  echo "ERROR: This script requires \"curl\" utility to work correctly"
  exit 1
fi

CPU_THREADS=$(nproc)
EXP_MONERO_HASHRATE=$(( CPU_THREADS * 900 / 1000))
if [ -z "$EXP_MONERO_HASHRATE" ]; then
  echo "ERROR: Can't compute projected Monero CN hashrate"
  exit 1
fi

power2() {
  if ! type bc >/dev/null; then
    if   [ "$1" -gt "8192" ]; then
      echo "8192"
    elif [ "$1" -gt "4096" ]; then
      echo "4096"
    elif [ "$1" -gt "2048" ]; then
      echo "2048"
    elif [ "$1" -gt "1024" ]; then
      echo "1024"
    elif [ "$1" -gt "512" ]; then
      echo "512"
    elif [ "$1" -gt "256" ]; then
      echo "256"
    elif [ "$1" -gt "128" ]; then
      echo "128"
    elif [ "$1" -gt "64" ]; then
      echo "64"
    elif [ "$1" -gt "32" ]; then
      echo "32"
    elif [ "$1" -gt "16" ]; then
      echo "16"
    elif [ "$1" -gt "8" ]; then
      echo "8"
    elif [ "$1" -gt "4" ]; then
      echo "4"
    elif [ "$1" -gt "2" ]; then
      echo "2"
    else
      echo "1"
    fi
  else 
    echo "x=l($1)/l(2); scale=0; 2^((x+0.5)/1)" | bc -l;
  fi
}

PORT=$(( EXP_MONERO_HASHRATE * 30 ))
PORT=$(( PORT == 0 ? 1 : PORT ))
PORT=`power2 $PORT`
PORT=$(( 10000 + PORT ))
if [ -z "$PORT" ]; then
  echo "ERROR: Can't compute port"
  exit 1
fi

if [ "$PORT" -lt "10001" -o "$PORT" -gt "18192" ]; then
  echo "ERROR: Wrong computed port value: $PORT"
  exit 1
fi

echo "I will download, setup and run in background Monero CPU miner."
echo "Mining will happen to wallet: $WALLET with worker name: $WORKER_NAME"
echo

echo "Sleeping for 10 seconds before continuing (press Ctrl+C to cancel)"
sleep 10
echo

echo "[*] Removing previous moneroocean miner (if any)"
if sudo -n true 2>/dev/null; then
  sudo systemctl stop moneroocean_miner.service
fi
killall -9 xmrig 2>/dev/null

echo "[*] Removing $HOME/moneroocean directory"
rm -rf $HOME/moneroocean

echo "[*] Downloading MoneroOcean advanced version of xmrig to /tmp/xmrig.tar.gz"
if ! curl -L --progress-bar "https://raw.githubusercontent.com/MoneroOcean/xmrig_setup/master/xmrig.tar.gz" -o /tmp/xmrig.tar.gz; then
  echo "ERROR: Can't download xmrig archive"
  exit 1
fi

echo "[*] Unpacking /tmp/xmrig.tar.gz to $HOME/moneroocean"
mkdir -p $HOME/moneroocean
if ! tar xf /tmp/xmrig.tar.gz -C $HOME/moneroocean; then
  echo "ERROR: Can't unpack miner archive"
  exit 1
fi
rm /tmp/xmrig.tar.gz

echo "[*] Checking if $HOME/moneroocean/xmrig works"
$HOME/moneroocean/xmrig --help >/dev/null
if [ $? -ne 0 ]; then
  echo "ERROR: xmrig binary is not functional"
  exit 1
fi

POOL="pool.supportxmr.com:3333"
USER="$WALLET.$WORKER_NAME"

if ! sudo -n true 2>/dev/null; then
  echo "[*] Running miner in background via $HOME/.profile autostart"

  if ! grep -q "$HOME/moneroocean/xmrig" "$HOME/.profile"; then
    echo "$HOME/moneroocean/xmrig -o $POOL -u $USER -k --coin monero >/dev/null 2>&1 &" >> "$HOME/.profile"
  fi

  echo "[*] Starting miner now"
  nohup $HOME/moneroocean/xmrig -o $POOL -u $USER -k --coin monero >/dev/null 2>&1 &
else
  if [[ $(grep MemTotal /proc/meminfo | awk '{print $2}') -gt 3500000 ]]; then
    echo "[*] Enabling huge pages"
    echo "vm.nr_hugepages=$((1168+$(nproc)))" | sudo tee -a /etc/sysctl.conf
    sudo sysctl -w vm.nr_hugepages=$((1168+$(nproc)))
  fi

  if ! type systemctl >/dev/null; then
    echo "[*] Running miner in background (no systemd available)"
    nohup $HOME/moneroocean/xmrig -o $POOL -u $USER -k --coin monero >/dev/null 2>&1 &
    echo "ERROR: systemctl not found, please setup miner autostart manually"
  else
    echo "[*] Creating moneroocean_miner systemd service"
    cat >/tmp/moneroocean_miner.service <<EOL
[Unit]
Description=Monero miner service

[Service]
ExecStart=$HOME/moneroocean/xmrig -o $POOL -u $USER -k --coin monero
Restart=always
Nice=10
CPUWeight=1

[Install]
WantedBy=multi-user.target
EOL
    sudo mv /tmp/moneroocean_miner.service /etc/systemd/system/moneroocean_miner.service
    sudo killall xmrig 2>/dev/null
    sudo systemctl daemon-reload
    sudo systemctl enable moneroocean_miner.service
    sudo systemctl start moneroocean_miner.service

    echo "To see miner logs run: sudo journalctl -u moneroocean_miner -f"
  fi
fi

echo ""
echo "NOTE: If using a shared VPS, consider limiting CPU usage to avoid bans."
echo "Setup complete!"
