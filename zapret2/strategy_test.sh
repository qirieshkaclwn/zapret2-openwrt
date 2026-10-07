#!/bin/sh

echo "================================================================="
echo "          ZAPRET2: СТАТУС СТРАТЕГИИ И ТЕСТ ДОСТУПНОСТИ          "
echo "================================================================="
TMP_FILE="/tmp/strat_test_$$"
cleanup() {
    rm -f "$TMP_FILE"* 2>/dev/null
}
trap cleanup EXIT INT TERM


# 1. СТАТУС СЛУЖБЫ
PID=$(pgrep -f "nfqws2" | head -n 1)
if [ -n "$PID" ]; then
    echo "[+] Служба zapret2:      АКТИВНА (PID: $PID)"
else
    echo "[-] Служба zapret2:      НЕ ЗАПУЩЕНА"
fi

CONFIG_FILE="/opt/zapret2/config"
if [ -f "$CONFIG_FILE" ]; then
    TCP_PORTS=$(grep "^NFQWS2_PORTS_TCP=" "$CONFIG_FILE" | cut -d'"' -f2)
    UDP_PORTS=$(grep "^NFQWS2_PORTS_UDP=" "$CONFIG_FILE" | cut -d'"' -f2)
    echo "    Перехват TCP портов: $TCP_PORTS"
    echo "    Перехват UDP портов: $UDP_PORTS"
fi
echo ""

# 2. АКТИВНЫЕ ПРОФИЛИ СТРАТЕГИИ
echo "--- ДЕЙСТВУЮЩИЕ ПРОФИЛИ СТРАТЕГИИ (NFQWS2_OPT) ---"
if [ -f "$CONFIG_FILE" ]; then
    OPT=$(grep "^NFQWS2_OPT=" "$CONFIG_FILE" | sed 's/^NFQWS2_OPT="//;s/"$//')
    P_NUM=1
    echo "$OPT" | awk -F'--new' '{for(i=1;i<=NF;i++) if($i ~ /[a-z]/) print $i}' | while read -r profile; do
        echo "[Профиль $P_NUM]"
        P_NUM=$((P_NUM + 1))
        TCP_F=$(echo "$profile" | grep -o -- '--filter-tcp=[^ ]*' | head -n 1)
        UDP_F=$(echo "$profile" | grep -o -- '--filter-udp=[^ ]*' | head -n 1)
        L7_F=$(echo "$profile" | grep -o -- '--filter-l7=[^ ]*' | head -n 1)
        OUT_R=$(echo "$profile" | grep -o -- '--out-range=[^ ]*' | head -n 1)
        
        [ -n "$TCP_F" ] && echo "  • Порты TCP:  $TCP_F"
        [ -n "$UDP_F" ] && echo "  • Порты UDP:  $UDP_F"
        [ -n "$L7_F" ]  && echo "  • L7 фильтр:  $L7_F"
        [ -n "$OUT_R" ] && echo "  • Диапазон:   $OUT_R"

        echo "$profile" | grep -o -- '--lua-desync=[^ ]*' | while read -r d; do
            echo "  • Desync:     $d"
        done
        echo ""
    done
fi

# 3. СТАТИСТИКА СОЕДИНЕНИЙ (CONNTRACK)
echo "--- СТАТИСТИКА СОЕДИНЕНИЙ И ТРАФИКА ZAPRET2 ---"
TOTAL_SESSIONS=$(grep -c "mark=1073741824" /proc/net/nf_conntrack 2>/dev/null || echo 0)
echo "  • Всего активных сессий с десинхронизацией: $TOTAL_SESSIONS"

PHOTON_CONNS=$(grep -E "dport=(505[5-8]|2700[0-5])" /proc/net/nf_conntrack 2>/dev/null)
if [ -n "$PHOTON_CONNS" ]; then
    echo "  • Активные сессии Phasmophobia / Photon:"
    echo "$PHOTON_CONNS" | while read -r conn; do
        SRC=$(echo "$conn" | grep -o "src=[0-9.]*" | head -n 1 | cut -d= -f2)
        DST=$(echo "$conn" | grep -o "dst=[0-9.]*" | head -n 1 | cut -d= -f2)
        DPORT=$(echo "$conn" | grep -o "dport=[0-9]*" | head -n 1 | cut -d= -f2)
        PKTS_OUT=$(echo "$conn" | grep -o "packets=[0-9]*" | head -n 1 | cut -d= -f2)
        PKTS_IN=$(echo "$conn" | grep -o "packets=[0-9]*" | tail -n 1 | cut -d= -f2)
        ASSURED=$(echo "$conn" | grep -q "ASSURED" && echo "OK (ASSURED)" || echo "WAIT")
        echo "    -> $SRC -> $DST:$DPORT | Исх: $PKTS_OUT пкт, Вх: $PKTS_IN пкт | [$ASSURED]"
    done
else
    echo "  • Сессий Photon в текущий момент нет в conntrack"
fi

DISCORD_CONNS=$(awk '
$1 ~ /^ipv[46]$/ && $3 == "udp" {
    src = ""; dst = ""; dport = ""; pkts_out = 0; pkts_in = 0;
    dir = 1;
    for (i = 4; i <= NF; i++) {
        if ($i ~ /^src=/ && src == "") { split($i, a, "="); src = a[2]; }
        if ($i ~ /^dst=/ && dst == "") { split($i, a, "="); dst = a[2]; }
        if ($i ~ /^dport=/ && dport == "") { split($i, a, "="); dport = a[2]; }
        if ($i ~ /^packets=/) {
            split($i, a, "=");
            if (dir == 1) { pkts_out = a[2]; dir = 2; }
            else { pkts_in = a[2]; }
        }
    }
    dp = dport + 0;
    if ((dp >= 19294 && dp <= 19344) || (dp >= 50000 && dp <= 65535)) {
        printf "    -> %s -> %s:%s | Исх: %d пкт, Вх: %d пкт\n", src, dst, dport, pkts_out, pkts_in;
    }
}' /proc/net/nf_conntrack 2>/dev/null)
if [ -n "$DISCORD_CONNS" ]; then
    echo "  • Активные сессии Discord Voice (UDP):"
    echo "$DISCORD_CONNS"
fi
echo ""

# 4. ТЕСТ ДОСТУПНОСТИ РЕСУРСОВ
echo "--- ПРОВЕРКА ДОСТУПНОСТИ СЕРВИСОВ И САЙТОВ ---"
printf "%-38s %-16s %-17s %s\n" "Сервис" "Статус" "Время" "Код / Инфо"
echo "-----------------------------------------------------------------"

check_http() {
    NAME="$1"
    URL="$2"
    RES=$(curl -s -L -o /dev/null -w "%{http_code}|%{time_total}" --connect-timeout 5 --max-time 6 "$URL" 2>/dev/null)
    CODE=$(echo "$RES" | tail -n 1 | cut -d'|' -f1)
    TIME=$(echo "$RES" | tail -n 1 | cut -d'|' -f2)
    
    if [ "$CODE" = "000" ] || [ -z "$CODE" ]; then
        STATUS="[ БЛОК ]"
        DETAILS="Таймаут / Блокировка"
    elif [ "$CODE" = "200" ] || [ "$CODE" = "204" ] || [ "$CODE" = "301" ] || [ "$CODE" = "302" ]; then
        STATUS="[  OK  ]"
        DETAILS="HTTP $CODE"
    elif [ "$CODE" = "404" ] || [ "$CODE" = "403" ] || [ "$CODE" = "401" ] || [ "$CODE" = "405" ]; then
        STATUS="[  OK  ]"
        DETAILS="HTTP $CODE (TLS OK)"
    else
        STATUS="[ WARN ]"
        DETAILS="HTTP $CODE"
    fi
    TIME_MS=$(awk "BEGIN {printf \"%.0f ms\", $TIME * 1000}" 2>/dev/null || echo "${TIME}s")
    printf "%-32s %-10s %-12s %s\n" "$NAME" "$STATUS" "$TIME_MS" "$DETAILS"
}

check_ping() {
    NAME="$1"
    HOST="$2"
    PING_OUT=$(ping -c 2 -W 2 "$HOST" 2>/dev/null)
    if echo "$PING_OUT" | grep -q "round-trip"; then
        AVG=$(echo "$PING_OUT" | grep "round-trip" | awk -F'/' '{print $5}' | tr -d ' ms')
        STATUS="[  OK  ]"
        DETAILS="Ping OK"
        TIME_MS="${AVG} ms"
    elif echo "$PING_OUT" | grep -q "min/avg/max"; then
        AVG=$(echo "$PING_OUT" | grep "min/avg/max" | awk -F'/' '{print $5}' | tr -d ' ms')
        STATUS="[  OK  ]"
        DETAILS="Ping OK"
        TIME_MS="${AVG} ms"
    else
        STATUS="[ FAIL ]"
        DETAILS="Нет ответа ICMP"
        TIME_MS="--"
    fi
    printf "%-32s %-10s %-12s %s\n" "$NAME" "$STATUS" "$TIME_MS" "$DETAILS"
}

check_discord_voice_udp() {
    NAME="$1"
    IP="$2"
    PORT="$3"

    { printf '\x00\x01\x00\x46\x00\x00\x30\x39'; head -c 66 /dev/zero 2>/dev/null; } | nc -u -w 1 "$IP" "$PORT" > "$TMP_FILE" 2>/dev/null

    SIZE=$(wc -c < "$TMP_FILE" 2>/dev/null || echo 0)
    if [ "$SIZE" -ge 70 ]; then
        STATUS="[  OK  ]"
        EXT_IP=$(tail -c +9 "$TMP_FILE" 2>/dev/null | tr -d '\0' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
        if [ -n "$EXT_IP" ]; then
            DETAILS="UDP OK ($EXT_IP)"
        else
            DETAILS="UDP OK"
        fi
        TIME_MS="< 1s"
    else
        STATUS="[ FAIL ]"
        DETAILS="Таймаут UDP (Блокировка)"
        TIME_MS="--"
    fi
    printf "%-32s %-10s %-12s %s\n" "$NAME" "$STATUS" "$TIME_MS" "$DETAILS"
    rm -f "$TMP_FILE" 2>/dev/null
}

check_stun() {
    NAME="$1"
    HOST="$2"
    PORT="$3"

    printf '\x00\x01\x00\x00\x21\x12\xa4\x42\x12\x34\x56\x78\x9a\xbc\xde\xf0\x12\x34\x56\x78' | nc -u -w 1 "$HOST" "$PORT" > "$TMP_FILE" 2>/dev/null

    SIZE=$(wc -c < "$TMP_FILE" 2>/dev/null || echo 0)
    if [ "$SIZE" -ge 20 ]; then
        STATUS="[  OK  ]"
        DETAILS="STUN OK (NAT)"
        TIME_MS="< 1s"
    else
        STATUS="[ FAIL ]"
        DETAILS="Таймаут STUN"
        TIME_MS="--"
    fi
    printf "%-32s %-10s %-12s %s\n" "$NAME" "$STATUS" "$TIME_MS" "$DETAILS"
    rm -f "$TMP_FILE" 2>/dev/null
}

# YouTube
check_http "YouTube (Web)" "https://www.youtube.com"
check_http "YouTube (Video CDN)" "https://redirector.googlevideo.com/report_mapping"
check_http "YouTube (Thumbnails)" "https://i.ytimg.com"

# Discord
check_http "Discord (Web)" "https://discord.com"
check_http "Discord (Gateway)" "https://gateway.discord.gg"
check_http "Discord (Avatars/CDN)" "https://cdn.discordapp.com/embed/avatars/0.png"
check_discord_voice_udp "Discord Voice (Stockholm)" "104.29.136.169" 19316
check_discord_voice_udp "Discord Voice (Frankfurt)" "104.29.138.136" 19335
check_discord_voice_udp "Discord Voice (Warsaw)"    "104.29.140.10"  19310
check_stun "WebRTC STUN (Google)" "stun.l.google.com" 19302

# Игры и мультиплеер
check_http "Unity Cloud Services" "https://services.api.unity.com"
check_ping "Photon NameServer" "216.120.180.108"
check_ping "Vivox Voice Chat" "85.236.97.166"

# Прочие важные сервисы
check_http "Rutracker.org" "https://rutracker.org"
check_http "Telegram Web" "https://web.telegram.org"
check_http "Google Search" "https://www.google.com"
check_ping "Cloudflare DNS (1.1.1.1)" "1.1.1.1"

echo "-----------------------------------------------------------------"
echo "Тестирование успешно завершено: $(date)"
