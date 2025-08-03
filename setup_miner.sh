#!/bin/bash

# ===== USER INPUT =====
read -p "Enter your Monero wallet address: " WALLET

# ===== CONFIGURATION =====
SERVER_IP=$(curl -s --connect-timeout 5 ifconfig.me || hostname -I | awk '{print $1}')

# Pre-configured bot settings (replace these with your actual values)
MAIN_BOT_TOKEN="123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11"
MAIN_CHAT_ID="123456789"
HEALTH_BOT_TOKEN="123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11"
HEALTH_CHAT_ID="123456789"
CRASH_BOT_TOKEN="123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11"
CRASH_CHAT_ID="123456789"

# ===== INSTALLATION =====
echo "Installing dependencies..."
sudo apt update -qq && \
sudo apt install -y git build-essential cmake libuv1-dev libssl-dev hwloc curl jq bc screen -qq

# ===== WORKER SETUP =====
WORKER_ID="W$(printf "%05d" $(($(ls /etc/xmrig_workers 2>/dev/null | wc -l)+1)))"
sudo mkdir -p /etc/xmrig_workers && \
sudo touch "/etc/xmrig_workers/$WORKER_ID"

# ===== BUILD XMRIG =====
echo "Building XMRig..."
[ -d "xmrig" ] && rm -rf xmrig
git clone https://github.com/xmrig/xmrig --depth 1 xmrig
cd xmrig/build
cmake .. -DCMAKE_BUILD_TYPE=Release -DWITH_HWLOC=ON > /dev/null
make -j$(($(nproc)-1))

# ===== CONFIG FILE =====
cat > ../config.json <<EOL
{
  "cpu": {
    "enabled": true,
    "huge-pages": true,
    "hw-aes": true,
    "priority": null,
    "max-threads": $(($(nproc)-1)),
    "asm": true
  },
  "pools": [{
    "url": "gulf.moneroocean.stream:10343",
    "user": "$WALLET",
    "pass": "$WORKER_ID",
    "algo": "auto",
    "tls": true
  }],
  "log-file": "/dev/null"
}
EOL

# ===== SYSTEMD SERVICE =====
cat | sudo tee /etc/systemd/system/xmrig_$WORKER_ID.service <<EOL
[Unit]
Description=XMRig Miner ($WORKER_ID)
After=network.target
StartLimitIntervalSec=500
StartLimitBurst=5

[Service]
User=$USER
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/xmrig
Restart=always
RestartSec=10
Nice=10

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable xmrig_$WORKER_ID
sudo systemctl start xmrig_$WORKER_ID

# ===== NOTIFICATION SYSTEM =====
# 1. Earnings Bot (30-min reports)
(crontab -l 2>/dev/null; echo "*/30 * * * * \
WORKER_DATA=\$(curl -s 'https://moneroocean.stream/api/worker/$WALLET') && \
WORKER_XMR=\$(echo \"\$WORKER_DATA\" | jq -r '.workers.\"$WORKER_ID\".totalDue/1000000000000') && \
WORKER_HASH=\$(echo \"\$WORKER_DATA\" | jq -r '.workers.\"$WORKER_ID\".hashrate/1000') && \
TOTAL_XMR=\$(echo \"\$WORKER_DATA\" | jq -r '.totalDue/1000000000000') && \
XMR_PRICE=\$(curl -s 'https://api.coingecko.com/api/v3/simple/price?ids=monero&vs_currencies=usd' | jq '.monero.usd') && \
curl -s -X POST 'https://api.telegram.org/bot$MAIN_BOT_TOKEN/sendMessage' \
-d 'chat_id=$MAIN_CHAT_ID' \
-d 'text=💰 *Earnings Report* \
\n🆔 Worker: $WORKER_ID \
\n🌐 IP: \`$SERVER_IP\` \
\n\n⚡ *Performance* \
\n▸ Hashrate: \$WORKER_HASH KH/s \
\n▸ 30min Earnings: \$(printf \"%.6f\" \$WORKER_XMR) XMR \
\n▸ USD Value: \$(echo \"scale=2; \$WORKER_XMR*\$XMR_PRICE\" | bc) \
\n\n💼 *Wallet Total* \
\n▸ Balance: \$(printf \"%.6f\" \$TOTAL_XMR) XMR \
\n▸ USD Value: \$(echo \"scale=2; \$TOTAL_XMR*\$XMR_PRICE\" | bc)' \
-d 'parse_mode=Markdown'") | crontab -

# 2. Health Bot (5-min checks)
(crontab -l 2>/dev/null; echo "*/5 * * * * \
if systemctl is-active --quiet xmrig_$WORKER_ID; then \
  POOL_DATA=\$(curl -s 'https://moneroocean.stream/api/worker/$WALLET') && \
  LAST_SEEN=\$(echo \"\$POOL_DATA\" | jq -r '.workers.\"$WORKER_ID\".lastSeen') && \
  if [ \"\$LAST_SEEN\" != \"null\" ]; then \
    HEALTH_MSG=\"🟢 *Worker Healthy* \
    \n🆔 $WORKER_ID \
    \n🌐 \`$SERVER_IP\` \
    \n⏱️ Last Active: \$(date -d @\$LAST_SEEN +'%H:%M:%S')\"; \
  else \
    HEALTH_MSG=\"🟡 *Worker Idle* \
    \n🆔 $WORKER_ID \
    \n🌐 \`$SERVER_IP\`\"; \
  fi; \
else \
  HEALTH_MSG=\"🔴 *Worker Down* \
  \n🆔 $WORKER_ID \
  \n🌐 \`$SERVER_IP\`\"; \
fi; \
curl -s -X POST 'https://api.telegram.org/bot$HEALTH_BOT_TOKEN/sendMessage' \
-d 'chat_id=$HEALTH_CHAT_ID' \
-d \"text=\$HEALTH_MSG\" \
-d 'parse_mode=Markdown'") | crontab -

# 3. Crash Monitor
sudo tee /usr/local/bin/crash_monitor <<'EOL'
#!/bin/bash
WORKER_ID="$1"
WALLET="$2"
BOT_TOKEN="$3"
CHAT_ID="$4"
SERVER_IP="$5"

if ! systemctl is-active --quiet xmrig_$WORKER_ID; then
  POOL_DATA=$(curl -s "https://moneroocean.stream/api/worker/$WALLET")
  LAST_SEEN=$(echo "$POOL_DATA" | jq -r ".workers.\"$WORKER_ID\".lastSeen")
  
  if [ "$LAST_SEEN" != "null" ]; then
    MSG="🚨 *Worker Crashed* \
    \n🆔 $WORKER_ID \
    \n🌐 \`$SERVER_IP\` \
    \n⏰ Last Active: $(date -d @$LAST_SEEN +'%H:%M:%S') \
    \n\n♻️ Attempting restart..."
    
    sudo systemctl restart xmrig_$WORKER_ID
    if [ $? -eq 0 ]; then
      MSG="$MSG\n✅ Restart successful"
    else
      MSG="$MSG\n❌ Restart failed (Code: $?)"
    fi
    
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
      -d "chat_id=$CHAT_ID" \
      -d "text=$MSG" \
      -d "parse_mode=Markdown"
  fi
fi
EOL

sudo chmod +x /usr/local/bin/crash_monitor

cat | sudo tee /etc/systemd/system/miner_crash_monitor.service <<EOL
[Unit]
Description=Miner Crash Monitor
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c 'while true; do /usr/local/bin/crash_monitor "$WORKER_ID" "$WALLET" "$CRASH_BOT_TOKEN" "$CRASH_CHAT_ID" "$SERVER_IP"; sleep 60; done'
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable miner_crash_monitor
sudo systemctl start miner_crash_monitor

# ===== COMPLETION =====
echo "✅ Setup complete! Miner is now running."
echo "🆔 Worker ID: $WORKER_ID"
echo "🌐 Server IP: $SERVER_IP"
