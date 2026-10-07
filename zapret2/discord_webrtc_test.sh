#!/bin/sh
# =================================================================
#  Тестер WebRTC и голосового трафика Discord для OpenWrt / Linux
#  Работает в стандартном BusyBox /bin/sh без Python и зависимостей
# =================================================================

TMP_FILE="/tmp/webrtc_test_$$"
cleanup() {
    rm -f "$TMP_FILE"* 2>/dev/null
}
trap cleanup EXIT INT TERM

echo "================================================================="
echo "      OPENWRT: ТЕСТ WEBRTC И ГОЛОСОВОГО ТРАФИКА DISCORD (UDP)    "
echo "================================================================="

# Проверка наличия активных VPN интерфейсов
VPN_FOUND=""
for iface in $(ls /sys/class/net 2>/dev/null); do
    case "$iface" in
        tun*|wg*|amn*|ppp*|tap*)
            state=$(cat /sys/class/net/"$iface"/operstate 2>/dev/null)
            if [ "$state" = "up" ] || [ "$state" = "unknown" ]; then
                VPN_FOUND="${VPN_FOUND}${iface} "
            fi
            ;;
    esac
done

if [ -n "$VPN_FOUND" ]; then
    echo "[ВНИМАНИЕ] Обнаружены активные VPN-интерфейсы: $VPN_FOUND"
    echo "           Тест показывает доступность через туннель, а не прямого WAN."
else
    echo "[СТАТУС]   VPN-интерфейсов не обнаружено. Тест идет напрямую через WAN."
fi
echo ""

# Функция замера времени через /proc/uptime (в миллисекундах)
get_time_ms() {
    if [ -f /proc/uptime ]; then
        read -r up _ < /proc/uptime
        awk "BEGIN {print int($up * 1000)}" 2>/dev/null || echo 0
    else
        date +%s000 2>/dev/null || echo 0
    fi
}

printf "%-44s %-16s %-17s %s\n" "Сервис / Регион" "Статус" "Время" "Код / Инфо"
echo "-----------------------------------------------------------------"

# 1. Проверка WebRTC STUN (Binding Request RFC 5389, UDP)
check_stun() {
    NAME="$1"
    HOST="$2"
    PORT="$3"

    # STUN Binding Request: Type=0x0001, Len=0x0000, Magic=0x2112A442, TID=12 bytes
    printf '\x00\x01\x00\x00\x21\x12\xa4\x42\x12\x34\x56\x78\x9a\xbc\xde\xf0\x12\x34\x56\x78' | nc -u -w 1 "$HOST" "$PORT" > "$TMP_FILE" 2>/dev/null

    SIZE=$(wc -c < "$TMP_FILE" 2>/dev/null || echo 0)
    if [ "$SIZE" -ge 20 ]; then
        STATUS="[  OK  ]"
        DETAILS="STUN OK (Ответ получен)"
        TIME_MS="< 1s"
    else
        STATUS="[ FAIL ]"
        DETAILS="Таймаут (UDP отброшен)"
        TIME_MS="--"
    fi
    printf "%-32s %-10s %-12s %s\n" "$NAME" "$STATUS" "$TIME_MS" "$DETAILS"
    rm -f "$TMP_FILE" 2>/dev/null
}

# 2. Проверка сигнальных шлюзов Discord Media (TCP WSS порт 2083)
check_tcp_signal() {
    NAME="$1"
    HOST="$2"
    PORT="$3"

    T_START=$(get_time_ms)
    if nc -z -w 2 "$HOST" "$PORT" 2>/dev/null; then
        T_END=$(get_time_ms)
        DT=$((T_END - T_START))
        STATUS="[  OK  ]"
        DETAILS="TCP 2083 (Шлюз WSS готов)"
        TIME_MS="${DT} ms"
    elif curl -s -k --connect-timeout 2 -m 3 "https://${HOST}:${PORT}" >/dev/null 2>&1; then
        T_END=$(get_time_ms)
        DT=$((T_END - T_START))
        STATUS="[  OK  ]"
        DETAILS="TCP 2083 (Шлюз WSS готов)"
        TIME_MS="${DT} ms"
    else
        STATUS="[ FAIL ]"
        DETAILS="Таймаут TCP подключения"
        TIME_MS="--"
    fi
    printf "%-32s %-10s %-12s %s\n" "$NAME" "$STATUS" "$TIME_MS" "$DETAILS"
}

# 3. Проверка голосовых кластеров Discord (Сырой UDP IP Discovery 74 байта)
check_discord_voice_udp() {
    NAME="$1"
    IP="$2"
    PORT="$3"

    # Отправляем 8 байт заголовка + 66 байт нулей прямо в сокет
    { printf '\x00\x01\x00\x46\x00\x00\x30\x39'; head -c 66 /dev/zero 2>/dev/null; } | nc -u -w 1 "$IP" "$PORT" > "$TMP_FILE" 2>/dev/null

    SIZE=$(wc -c < "$TMP_FILE" 2>/dev/null || echo 0)
    if [ "$SIZE" -ge 70 ]; then
        STATUS="[  OK  ]"
        # Пропускаем первые 8 байт заголовка (Type, Length, SSRC) и извлекаем IP
        EXT_IP=$(tail -c +9 "$TMP_FILE" 2>/dev/null | tr -d '\0' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
        if [ -n "$EXT_IP" ]; then
            DETAILS="IP Discovery OK (IP: $EXT_IP)"
        else
            DETAILS="IP Discovery OK (Ответ получен)"
        fi
        TIME_MS="< 1s"
    else
        STATUS="[ FAIL ]"
        DETAILS="Таймаут (UDP отброшен)"
        TIME_MS="--"
    fi
    printf "%-32s %-10s %-12s %s\n" "$NAME" "$STATUS" "$TIME_MS" "$DETAILS"
    rm -f "$TMP_FILE" 2>/dev/null
}

# Тесты STUN
check_stun "WebRTC STUN (Google)" "stun.l.google.com" 19302
check_stun "WebRTC STUN (Cloudflare)" "stun.cloudflare.com" 3478

# Тесты сигнальных шлюзов WSS
check_tcp_signal "Discord Media WSS (Edge 1)" "162.159.138.234" 2083
check_tcp_signal "Discord Media WSS (Edge 2)" "162.159.128.233" 2083

# Тесты реальных голосовых кластеров Discord Voice UDP
check_discord_voice_udp "Discord Voice (Stockholm)" "104.29.136.169" 19316
check_discord_voice_udp "Discord Voice (Frankfurt)" "104.29.138.136" 19335
check_discord_voice_udp "Discord Voice (Warsaw)"    "104.29.140.10"  19310
check_discord_voice_udp "Discord Voice (Helsinki)"  "104.29.144.15"  19320

echo "-----------------------------------------------------------------"

if [ -f /proc/net/nf_conntrack ]; then
    DISCORD_FLOWS=$(awk '
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
            printf "  • LAN: %s -> Сервер: %s:%s | Исх: %d пкт, Вх: %d пкт\n", src, dst, dport, pkts_out, pkts_in;
        }
    }' /proc/net/nf_conntrack 2>/dev/null)
    if [ -n "$DISCORD_FLOWS" ]; then
        echo "--- АКТИВНЫЕ ГОЛОСОВЫЕ UDP СЕССИИ В CONNTRACK РОУТЕРА ---"
        echo "$DISCORD_FLOWS"
        echo "-----------------------------------------------------------------"
    fi
fi

echo "Тестирование завершено: $(date)"
