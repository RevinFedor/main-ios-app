#!/bin/bash
set -e

# ============================================================
# Habit Tracker — Wireless Deploy
#   ./deploy.sh          build + install
#   ./deploy.sh --check  only diagnose, no build
#
# Logs: deploy-logs/deploy-*.log  (diagnostics, no ANSI)
#       deploy-logs/build-*.log   (xcodebuild output)
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/HabitTrackerSwift"
PROJECT="$PROJECT_DIR/HabitTracker.xcodeproj"
SCHEME="HabitTracker"
CONFIG="Release"

CHECK_ONLY=false
for a in "$@"; do
    case "$a" in --check|-c) CHECK_ONLY=true ;; --help|-h) echo "Usage: ./deploy.sh [--check]"; echo "  --check  diagnose only, skip build"; exit 0 ;; esac
done

# --- Logging ---
TS=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_DIR="$SCRIPT_DIR/deploy-logs"; mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/deploy-$TS.log"; BUILD_LOG="$LOG_DIR/build-$TS.log"
exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1

# --- Colors ---
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
step() { echo -e "\n${B}${C}── $1${N}"; }
ok()   { echo -e "  ${G}✓${N} $1"; }
warn() { echo -e "  ${Y}⚠${N} $1"; }
err()  { echo -e "  ${R}✗${N} $1"; }

# ============================================================
echo -e "\n${B}═══════════════════════════════════════${N}"
echo -e "${B}  Habit Tracker · Wireless Deploy${N}"
echo -e "${B}═══════════════════════════════════════${N}"
echo -e "Log:  $LOG_FILE"
echo -e "Build log: $BUILD_LOG"

# ============================================================
# STEP 1 — Prerequisites
# ============================================================
step "1/4  Prerequisites"

for cmd in xcodebuild xcrun; do
    command -v "$cmd" &>/dev/null || { err "$cmd not found"; exit 1; }
done
ok "xcodebuild $(xcodebuild -version 2>&1 | head -1 | awk '{print $2}')"
[ -d "$PROJECT" ] || { err "Project not found: $PROJECT"; exit 1; }
ok "Project: $PROJECT"

# ============================================================
# Pre-step — Wake CoreDevice tunnel if dormant
# ============================================================
# After Mac reboot, after iOS major update, or after iPhone was offline for
# a long time, CoreDevice tunnel can sit at tunnelState=unavailable even
# when iPhone is on the same WiFi and reachable via Bonjour. xcodebuild
# refuses to build under id=<UDID> in that state. The fix is to give Xcode
# a chance to spawn its CoreDevice background services — opening the app
# in the background is enough; we don't need the UI. Wait up to 90s for
# tunnel to flip to "connected" (also covers iOS first-time DDI "Preparing
# iPhone" pass that runs after a fresh iOS install).
#
# Idempotent: when tunnel is already connected this block is a no-op.

probe_tunnel() {
    xcrun devicectl list devices --json-output /tmp/habit-devices-probe.json &>/dev/null
    python3 -c "
import json
try:
    d=json.load(open('/tmp/habit-devices-probe.json'))
    devs=d.get('result',{}).get('devices',[])
    if not devs:
        print('NONE'); exit()
    print(devs[0].get('connectionProperties',{}).get('tunnelState','unknown'))
except Exception:
    print('ERROR')
" 2>/dev/null
}

# Track whether WE started Xcode this run — if yes, we close it at script
# exit. If Xcode was already running (user has it open for some other work),
# we DON'T touch it. pgrep matches the Xcode.app main binary specifically
# to avoid false-positives like xcodebuild.
XCODE_WAS_RUNNING=false
if pgrep -xf "/Applications/Xcode.app/Contents/MacOS/Xcode" &>/dev/null; then
    XCODE_WAS_RUNNING=true
fi

cleanup_xcode() {
    if [ "$XCODE_WAS_RUNNING" = "false" ] && pgrep -xf "/Applications/Xcode.app/Contents/MacOS/Xcode" &>/dev/null; then
        echo -e "${C}ℹ Closing Xcode (was launched by deploy.sh)${N}"
        osascript -e 'tell application "Xcode" to quit' 2>/dev/null || true
        # AppleScript "quit" is async — Xcode acknowledges immediately but
        # takes 1-3s to actually terminate. Wait for the process to die so
        # callers / pgrep checks see a consistent state. Hard-kill if it
        # refuses to exit after 8s.
        for _ in 1 2 3 4 5 6 7 8; do
            sleep 1
            pgrep -xf "/Applications/Xcode.app/Contents/MacOS/Xcode" &>/dev/null || return
        done
        pkill -x Xcode 2>/dev/null || true
    fi
}
# Ensure Xcode is closed even if script fails / is interrupted.
trap cleanup_xcode EXIT INT TERM

TUNNEL_INITIAL=$(probe_tunnel)
# Only wake Xcode when tunnel is REALLY broken. Sleeping iPhone shows up as
# `disconnected` and `devicectl device install app` brings the tunnel back on
# its own — no need to spend 90s spinning Xcode for that. The states that
# actually require Xcode background services to start are:
#   unavailable — CoreDevice services not running at all
#   unknown / ERROR / "" — probe failed, give Xcode a chance
case "$TUNNEL_INITIAL" in
    unavailable|unknown|ERROR|"") NEEDS_WAKE=true ;;
    *) NEEDS_WAKE=false ;;
esac
if [ "$NEEDS_WAKE" = "true" ] && [ "$TUNNEL_INITIAL" != "NONE" ]; then
    step "Pre  CoreDevice tunnel (state=$TUNNEL_INITIAL) — waking Xcode background services"
    # -g: don't bring to foreground; -j: hide window; -a Xcode: target the app.
    open -gja Xcode 2>/dev/null || true
    # Poll up to 90s, log progress.
    WAITED=0
    while [ $WAITED -lt 90 ]; do
        sleep 3
        WAITED=$((WAITED+3))
        S=$(probe_tunnel)
        if [ "$S" = "connected" ] || [ "$S" = "disconnected" ]; then
            ok "Tunnel reachable in ${WAITED}s (state=$S)"
            break
        fi
        echo -n "."
    done
    echo ""
    if [ "$S" != "connected" ] && [ "$S" != "disconnected" ]; then
        warn "Tunnel didn't come up after 90s — will let xcodebuild try anyway"
        warn "If build fails: wait for one-time 'Preparing iPhone' to finish, then re-run ./deploy.sh"
    fi
fi

# ============================================================
# STEP 2 — Unified Device + Network Diagnostic
# ============================================================
step "2/4  Device & Network Diagnostic"

# --- Run ONE python script that does everything ---
FULL_DIAG=$(python3 << 'PYEOF'
import json, subprocess, os, sys, datetime

result = {
    'device_found': False,
    'device_count': 0,
    'device_name': '',
    'device_model': '',
    'device_os': '',
    'device_udid': '',
    'device_identifier': '',
    'device_paired': '',
    'device_tunnel': '',
    'device_lastseen': '',
    'device_ddi': '',
    'device_devmode': '',
    'vpn_processes': '',
    'vpn_tunnel_iface': '',
    'vpn_tunnel_ip': '',
    'mdns_reachable': False,
    'errors': [],
    'warnings': [],
    'verdict': 'UNKNOWN',
    'verdict_action': ''
}

# --- Device check ---
try:
    tmpf = '/tmp/habit-devices.json'
    subprocess.run(['xcrun', 'devicectl', 'list', 'devices', '--json-output', tmpf],
                   capture_output=True, timeout=15)
    with open(tmpf) as f:
        data = json.load(f)
    devices = data.get('result', {}).get('devices', [])
    result['device_count'] = len(devices)

    if len(devices) == 0:
        result['errors'].append('NEVER_PAIRED')
        result['verdict'] = 'NEVER_PAIRED'
        result['verdict_action'] = (
            'iPhone никогда не был подключен к этому Mac.\n'
            '  1. Подключи iPhone по USB к Mac\n'
            '  2. На iPhone нажми "Доверять этому компьютеру"\n'
            '  3. Открой Xcode → Window → Devices and Simulators\n'
            '  4. Включи "Connect via network" для своего iPhone'
        )
    else:
        result['device_found'] = True
        d = devices[0]
        props = d.get('deviceProperties', {})
        conn = d.get('connectionProperties', {})
        hw = d.get('hardwareProperties', {})

        result['device_name'] = props.get('name', '?')
        result['device_model'] = hw.get('marketingName', '?')
        result['device_os'] = props.get('osVersionNumber', '?')
        result['device_udid'] = hw.get('udid', '?')
        result['device_identifier'] = d.get('identifier', '?')
        result['device_paired'] = conn.get('pairingState', '?')
        result['device_tunnel'] = conn.get('tunnelState', '?')
        result['device_lastseen'] = conn.get('lastConnectionDate', '?')
        result['device_ddi'] = str(props.get('ddiServicesAvailable', '?'))
        result['device_devmode'] = str(props.get('developerModeStatus', '?'))

        # Parse lastSeen date
        if result['device_lastseen'] and result['device_lastseen'] != '?':
            try:
                dts = result['device_lastseen'].replace('T', ' ')[:19]
                last_dt = datetime.datetime.strptime(dts, '%Y-%m-%d %H:%M:%S')
                days_ago = (datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) - last_dt).days
                result['device_lastseen_days'] = days_ago
            except:
                result['device_lastseen_days'] = None

except Exception as e:
    result['errors'].append(f'DEVICECTL_FAILED: {e}')

# --- VPN process check ---
try:
    vpn_out = subprocess.run(['bash', '-c',
        'ps aux 2>/dev/null | grep -iE "wireguard-go|amneziavpn|openvpn|tunnelblick" | grep -v grep'],
        capture_output=True, text=True, timeout=5)
    if vpn_out.stdout.strip():
        result['vpn_processes'] = vpn_out.stdout.strip()
        result['errors'].append('VPN_RUNNING')
except:
    pass

# --- VPN tunnel interfaces ---
try:
    if_out = subprocess.run(['bash', '-c',
        '''for iface in $(ifconfig 2>/dev/null | grep "^utun" | cut -d: -f1); do ip=$(ifconfig $iface 2>/dev/null | grep "inet " | awk '{print $2}'); [ -n "$ip" ] && echo "$iface $ip"; done'''],
        capture_output=True, text=True, timeout=5)
    lines = if_out.stdout.strip().split('\n')
    for line in lines:
        if line.strip():
            parts = line.strip().split()
            if len(parts) >= 2:
                result['vpn_tunnel_iface'] = parts[0]
                result['vpn_tunnel_ip'] = parts[1]
                break
    if result['vpn_tunnel_iface'] and not result['vpn_processes']:
        result['errors'].append('VPN_TUNNEL')
except:
    pass

# --- mDNS: real check via Bonjour browse, not scutil flag ---
# The scutil "Reachable" flag is unreliable (often "Not Reachable" even when Bonjour works fine).
# Real test: can we discover ANY local Bonjour service in 2 seconds?
try:
    mdns_out = subprocess.run(['bash', '-c',
        'timeout 2 dns-sd -B _services._dns-sd._udp local. 2>&1 | grep -c "Add" || true'],
        capture_output=True, text=True, timeout=5)
    found_count = int(mdns_out.stdout.strip() or '0')
    result['mdns_reachable'] = (found_count > 0)
    result['mdns_services_found'] = found_count
except:
    result['mdns_reachable'] = False

# --- Can we resolve the iPhone via Bonjour? (real test) ---
try:
    if result.get('device_name'):
        # Try to resolve iPhone.local — this is the real test
        host = f"{result['device_name']}.local"
        resolve_out = subprocess.run(['bash', '-c',
            f'timeout 3 dns-sd -G v4 {host} 2>&1 | grep -m1 "Add" || true'],
            capture_output=True, text=True, timeout=5)
        if 'Add' in resolve_out.stdout:
            result['iphone_reachable_via_bonjour'] = True
            # Extract IP
            for word in resolve_out.stdout.split():
                if word.count('.') == 3 and all(p.isdigit() for p in word.split('.')):
                    result['iphone_local_ip'] = word
                    break
        else:
            result['iphone_reachable_via_bonjour'] = False
except:
    result['iphone_reachable_via_bonjour'] = False

# --- Xcode destinations ---
try:
    xcdest = subprocess.run(['xcodebuild', '-showdestinations',
        '-project', sys.argv[1] if len(sys.argv) > 1 else '/Users/fedor/Desktop/vs-code/habit-tracker/HabitTrackerSwift/HabitTracker.xcodeproj',
        '-scheme', 'HabitTracker'],
        capture_output=True, text=True, timeout=30)
    # Check if physical iPhone appears (not simulator, not placeholder)
    for line in xcdest.stdout.split('\n'):
        if 'platform:iOS, id:' in line and 'placeholder' not in line and 'Simulator' not in line:
            result['xcode_sees_device'] = line.strip()
            break
except:
    pass

# --- Final verdict — root cause analysis ---
# IMPORTANT: VPN/wireguard processes are NOT a blocker by themselves.
# What matters: can devicectl tunnel actually connect?
# The real root cause is almost always DDI_MISSING or stale pairing.

result['errors'] = []  # reset, we re-classify properly below

if not result['device_found']:
    result['verdict'] = 'NEVER_PAIRED'
    result['errors'] = ['NEVER_PAIRED']
    result['verdict_action'] = (
        'iPhone никогда не был подключен к этому Mac через CoreDevice.\n'
        '  Подключи iPhone по USB, нажми "Trust" на iPhone, открой Xcode\n'
        '  → Window → Devices and Simulators. После этого попробуй снова.'
    )
elif result['device_paired'] == 'paired':
    # Paired = devicectl install will work, even if tunnel is "disconnected".
    # The install command auto-enables DDI and brings up tunnel as needed.
    result['verdict'] = 'READY'
    result['verdict_action'] = f'Device is paired ({result.get("device_tunnel", "?")} tunnel). devicectl will handle DDI mount.'
else:
    # Device known, tunnel down — find the REAL reason
    reasons = []
    days = result.get('device_lastseen_days')

    if result.get('device_ddi') == 'False':
        reasons.append('DDI_MISSING')

    if days is not None and days > 7:
        reasons.append(f'STALE_PAIRING')

    # Only flag mDNS as a problem if we ALSO can't resolve iPhone.local
    # (scutil's "Reachable" flag is unreliable — see comment above)
    if not result.get('iphone_reachable_via_bonjour') and not result.get('mdns_reachable'):
        reasons.append('BONJOUR_BLOCKED')

    if not reasons:
        # Device known, tunnel down, but no clear cause
        reasons.append('UNKNOWN_TUNNEL_DOWN')

    result['verdict'] = 'DEVICE_UNREACHABLE'
    result['errors'] = reasons

    action = []
    action.append(f'iPhone "{result["device_name"]}" ({result["device_model"]}, iOS {result["device_os"]})')
    action.append('найден в системе devicectl, но CoreDevice tunnel НЕ установлен.')
    action.append('')
    action.append('Что обнаружено:')

    if result.get('iphone_reachable_via_bonjour'):
        ip = result.get('iphone_local_ip', '?')
        action.append(f'  ✓ iPhone виден в локальной сети как {result["device_name"]}.local → {ip}')
        action.append('  → Сеть и Bonjour работают нормально.')
    elif result.get('mdns_reachable'):
        action.append('  ✓ Bonjour работает, но конкретно iPhone не отвечает.')
        action.append('  → Возможно VPN на iPhone или iPhone в другой WiFi сети.')
    else:
        action.append('  ✗ Bonjour не находит сервисы в сети — что-то не так с mDNS.')

    if result.get('vpn_tunnel_iface'):
        action.append(f'  ℹ Активен VPN-туннель {result["vpn_tunnel_iface"]} ({result["vpn_tunnel_ip"]}).')
        action.append(f'    На локальный трафик 192.168.x.x он обычно не влияет,')
        action.append(f'    но это можно проверить — отключи VPN и сравни.')

    action.append('')
    action.append('Главная причина (по приоритету):')

    if 'DDI_MISSING' in reasons:
        action.append('  ★ ddiServicesAvailable=False — Developer Disk Image НЕ загружен на iPhone.')
        action.append('    Это означает: CoreDevice сервисы недоступны до загрузки DDI.')
        action.append('    DDI загружается только когда iPhone подключен по USB и Xcode')
        action.append('    активно с ним работает.')

    if 'STALE_PAIRING' in reasons:
        action.append(f'  ★ Последнее подключение к Xcode было {days} дн. назад.')
        action.append('    Pairing может быть протухшим. iOS периодически требует')
        action.append('    повторного USB-подключения для refresh.')

    if 'BONJOUR_BLOCKED' in reasons:
        action.append('  ★ Bonjour/mDNS не работает.')
        action.append('    Проверь VPN, файрвол, или подключи Mac/iPhone к одной WiFi.')

    if 'UNKNOWN_TUNNEL_DOWN' in reasons:
        action.append('  ? Причина непонятна. Скорее всего нужен USB-коннект к Xcode.')

    action.append('')
    action.append('Решение (99% случаев):')
    action.append('  1. Подключи iPhone к Mac по USB-кабелю')
    action.append('  2. На iPhone нажми "Trust" если спросит')
    action.append('  3. Открой Xcode → Window → Devices and Simulators')
    action.append('  4. Выбери свой iPhone в списке')
    action.append('  5. Дождись окончания "Preparing iPhone for development..."')
    action.append('     (это и есть загрузка DDI — может занять 2-5 минут)')
    action.append('  6. Поставь галочку "Connect via network"')
    action.append('  7. Отключи USB-кабель')
    action.append('  8. Запусти: ./deploy.sh')

    result['verdict_action'] = '\n'.join(action)

# Print JSON for bash to parse
print(json.dumps(result, ensure_ascii=False, default=str))
PYEOF
)

# --- Parse verdict ---
VERDICT=$(echo "$FULL_DIAG" | python3 -c "import sys,json; print(json.load(sys.stdin)['verdict'])" 2>/dev/null || echo "ERROR")
VERDICT_ACTION=$(echo "$FULL_DIAG" | python3 -c "import sys,json; print(json.load(sys.stdin)['verdict_action'])" 2>/dev/null || echo "")
DEVICE_FOUND=$(echo "$FULL_DIAG" | python3 -c "import sys,json; print(json.load(sys.stdin)['device_found'])" 2>/dev/null || echo "False")
DEVICE_READY=false; [ "$VERDICT" = "READY" ] && DEVICE_READY=true

# --- Print diagnostic summary ---
echo -e "\n${B}Diagnostic Result:${N}"

# Device info
if [ "$DEVICE_FOUND" = "True" ]; then
    MODEL=$(echo "$FULL_DIAG" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'{d[\"device_model\"]} · iOS {d[\"device_os\"]}')" 2>/dev/null)
    NAME=$(echo "$FULL_DIAG" | python3 -c "import sys,json; print(json.load(sys.stdin)['device_name'])" 2>/dev/null)
    UDID=$(echo "$FULL_DIAG" | python3 -c "import sys,json; print(json.load(sys.stdin)['device_udid'])" 2>/dev/null)
    PAIRED=$(echo "$FULL_DIAG" | python3 -c "import sys,json; print(json.load(sys.stdin)['device_paired'])" 2>/dev/null)
    TUNNEL=$(echo "$FULL_DIAG" | python3 -c "import sys,json; print(json.load(sys.stdin)['device_tunnel'])" 2>/dev/null)
    LASTSEEN=$(echo "$FULL_DIAG" | python3 -c "import sys,json; print(json.load(sys.stdin)['device_lastseen'])" 2>/dev/null)
    DDI=$(echo "$FULL_DIAG" | python3 -c "import sys,json; print(json.load(sys.stdin)['device_ddi'])" 2>/dev/null)
    DEVMODE=$(echo "$FULL_DIAG" | python3 -c "import sys,json; print(json.load(sys.stdin)['device_devmode'])" 2>/dev/null)
    DAYS_AGO=$(echo "$FULL_DIAG" | python3 -c "
import sys,json; d=json.load(sys.stdin)
v=d.get('device_lastseen_days')
print(v if v is not None else '?')
" 2>/dev/null)

    ok "Device:  $MODEL"
    ok "Name:    $NAME"
    ok "UDID:    $UDID"
    echo -e "  Paired:  $PAIRED"
    echo -e "  Tunnel:  $TUNNEL"
    echo -e "  DDI:     $DDI"
    echo -e "  DevMode: $DEVMODE"
    echo -e "  Last seen: ${LASTSEEN} (${DAYS_AGO} days ago)"
else
    warn "Device:  NOT FOUND — iPhone never paired with this Mac"
fi

# Network info
MDNS_OK=$(echo "$FULL_DIAG" | python3 -c "import sys,json; print(json.load(sys.stdin)['mdns_reachable'])" 2>/dev/null)
MDNS_COUNT=$(echo "$FULL_DIAG" | python3 -c "import sys,json; print(json.load(sys.stdin).get('mdns_services_found',0))" 2>/dev/null)
IPHONE_BONJOUR=$(echo "$FULL_DIAG" | python3 -c "import sys,json; print(json.load(sys.stdin).get('iphone_reachable_via_bonjour', False))" 2>/dev/null)
IPHONE_IP=$(echo "$FULL_DIAG" | python3 -c "import sys,json; print(json.load(sys.stdin).get('iphone_local_ip', ''))" 2>/dev/null)
VPN_IFACE=$(echo "$FULL_DIAG" | python3 -c "import sys,json; print(json.load(sys.stdin)['vpn_tunnel_iface'] or '')" 2>/dev/null)
VPN_IP=$(echo "$FULL_DIAG" | python3 -c "import sys,json; print(json.load(sys.stdin)['vpn_tunnel_ip'] or '')" 2>/dev/null)
VPN_PROCS=$(echo "$FULL_DIAG" | python3 -c "import sys,json; print(json.load(sys.stdin)['vpn_processes'] or '')" 2>/dev/null)

if [ "$MDNS_OK" = "True" ]; then
    ok "Bonjour: working ($MDNS_COUNT services discoverable)"
else
    warn "Bonjour: NOT working (no services discoverable in 2s)"
fi

if [ "$IPHONE_BONJOUR" = "True" ]; then
    ok "iPhone in WiFi: ${DEVICE_NAME}.local → $IPHONE_IP"
elif [ -n "$DEVICE_NAME" ]; then
    warn "iPhone in WiFi: ${DEVICE_NAME}.local NOT resolvable via Bonjour"
fi

# VPN is informational only — it's almost never the actual blocker
if [ -n "$VPN_PROCS" ]; then
    APPNAME=$(echo "$VPN_PROCS" | grep -oE 'AmneziaVPN|wireguard-go|OpenVPN|Tunnelblick' | head -1)
    echo -e "  ${C}ℹ${N} VPN:     $APPNAME running (informational, не блокирует CoreDevice)"
elif [ -n "$VPN_IFACE" ]; then
    echo -e "  ${C}ℹ${N} VPN:     tunnel $VPN_IFACE ($VPN_IP) (informational)"
else
    ok "VPN:     none"
fi

# --- Verdict ---
echo ""
case "$VERDICT" in
    READY)
        echo -e "${G}${B}═══════════════════════════════════════${N}"
        echo -e "${G}${B}  ✓ READY — device is reachable${N}"
        echo -e "${G}${B}═══════════════════════════════════════${N}"
        ;;
    NEVER_PAIRED)
        echo -e "${R}${B}═══════════════════════════════════════${N}"
        echo -e "${R}${B}  ✗ NEVER PAIRED${N}"
        echo -e "${R}${B}═══════════════════════════════════════${N}"
        echo -e "\n$VERDICT_ACTION\n"
        ;;
    DEVICE_UNREACHABLE)
        echo -e "${Y}${B}═══════════════════════════════════════${N}"
        echo -e "${Y}${B}  ✗ DEVICE UNREACHABLE${N}"
        echo -e "${Y}${B}═══════════════════════════════════════${N}"
        echo -e "\n$VERDICT_ACTION\n"
        ;;
    *)
        echo -e "${Y}${B}═══════════════════════════════════════${N}"
        echo -e "${Y}${B}  ✗ UNKNOWN STATE${N}"
        echo -e "${Y}${B}═══════════════════════════════════════${N}"
        echo -e "\n$VERDICT_ACTION\n"
        ;;
esac

# Extract UDID and identifier for build step
DEVICE_UDID=$(echo "$FULL_DIAG" | python3 -c "import sys,json; print(json.load(sys.stdin).get('device_udid',''))" 2>/dev/null || echo "")
DEVICE_IDENTIFIER=$(echo "$FULL_DIAG" | python3 -c "import sys,json; print(json.load(sys.stdin).get('device_identifier',''))" 2>/dev/null || echo "")
DEVICE_NAME=$(echo "$FULL_DIAG" | python3 -c "import sys,json; print(json.load(sys.stdin).get('device_name',''))" 2>/dev/null || echo "")

# ============================================================
# If --check, stop here
# ============================================================
if $CHECK_ONLY; then
    echo -e "Check complete (--check mode). Log: $LOG_FILE\n"
    rm -f "$DEVICE_JSON_FILE" 2>/dev/null
    exit 0
fi

# ============================================================
# If not READY, exit
# ============================================================
if ! $DEVICE_READY; then
    echo -e "Cannot deploy. Fix the issue above and re-run ./deploy.sh"
    echo -e "For diagnostic only: ./deploy.sh --check\n"
    rm -f "$DEVICE_JSON_FILE" 2>/dev/null
    exit 1
fi

# ============================================================
# STEP 3 — Build
# ============================================================
step "3/4  Build"

DERIVED_DATA="$SCRIPT_DIR/build/DerivedData"
rm -rf "$DERIVED_DATA" 2>/dev/null
mkdir -p "$SCRIPT_DIR/build"

xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "id=$DEVICE_UDID" \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    2>&1 | tee "$BUILD_LOG"

[ ${PIPESTATUS[0]} -eq 0 ] || { err "Build failed: $BUILD_LOG"; exit 1; }
ok "Build succeeded"

# ============================================================
# STEP 4 — Install
# ============================================================
step "4/4  Install"

APP_PATH=$(find "$DERIVED_DATA/Build/Products/$CONFIG-iphoneos" \
    -name "*.app" -type d ! -path "*/PlugIns/*" ! -name "*Widget*" 2>/dev/null | head -1)

[ -n "$APP_PATH" ] || { err ".app not found in build output"; exit 1; }
ok "App: $(basename "$APP_PATH") ($(du -sh "$APP_PATH" | cut -f1))"

echo -e "  Installing to $DEVICE_NAME..."
# On a freshly-woken Xcode the CoreDevice tunnel comes up before the
# installcoordination_proxy service is ready, and the first install request
# fails with IXRemoteErrorDomain code 5 / CoreDeviceError 3002. The retry
# below gives the service ~25s extra to register itself, then tries once
# more. This is exactly what manual Xcode "Preparing iPhone" does — it
# waits for installcoordination before unblocking the Run button.
INSTALL_LOG="/tmp/habit-install.log"
xcrun devicectl device install app --device "$DEVICE_IDENTIFIER" "$APP_PATH" 2>&1 | tee "$INSTALL_LOG"
INSTALL_RC=${PIPESTATUS[0]}
if [ $INSTALL_RC -ne 0 ] && grep -q "installcoordination_proxy\|IXRemoteErrorDomain error 5\|CoreDeviceError error 3002" "$INSTALL_LOG"; then
    warn "installcoordination service not ready yet — waiting 25s and retrying once"
    sleep 25
    xcrun devicectl device install app --device "$DEVICE_IDENTIFIER" "$APP_PATH" 2>&1 | tee "$INSTALL_LOG"
    INSTALL_RC=${PIPESTATUS[0]}
fi
[ $INSTALL_RC -eq 0 ] || { err "Install failed"; exit 1; }

echo -e "\n${G}${B}═══════════════════════════════════════${N}"
echo -e "${G}${B}  ✓ INSTALLED on $DEVICE_NAME${N}"
echo -e "${G}${B}═══════════════════════════════════════${N}"

echo -e "\n${B}Если запускаешь приложение первый раз (или после обновления сертификата):${N}"
echo -e "  При тапе на иконку появится: ${Y}\"Untrusted Developer\"${N}"
echo -e ""
echo -e "  На iPhone:"
echo -e "    1. Открой ${B}Настройки${N}"
echo -e "    2. ${B}Основные${N} (General)"
echo -e "    3. Пролистай в самый низ → ${B}VPN и управление устройством${N}"
echo -e "       (VPN & Device Management)"
echo -e "    4. В разделе ${B}ПО разработчика${N} (Developer App) тапни на свой Apple ID"
echo -e "    5. Нажми ${B}Доверять${N} (Trust)"
echo -e ""
echo -e "  После этого приложение запустится. Делать это нужно один раз."
echo -e "  Сертификат истекает через 7 дней — тогда просто запусти ./deploy.sh снова.\n"

rm -f "$DEVICE_JSON_FILE" 2>/dev/null
