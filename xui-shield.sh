#!/usr/bin/env bash
# =============================================================================
#  XUI-SHIELD · 3x-ui 一鍵抗封鎖 + 自動化防火牆 + 每日備份
# -----------------------------------------------------------------------------
#  作者 / 維護   NatShift-N
#  Telegram      @NatShift        →  https://t.me/NatShift
#  VPS 官網      hkvps.xyz        →  https://hkvps.xyz
#
#  提供服務
#    · 香港動態 IP NAT VPS：PVE / KVM 全虛擬化，不是容器
#    · 每天自動更換 IP，降低被針對與被封鎖的風險
#    · 3x-ui / Xray / Sing-box 面板代部署、節點調優、協議偽裝
#    · 伺服器疑難排解、數據遷移、7x24 代維運
#
#  版權所有 (c) 2025-2026 NatShift-N。可自由使用及修改，請保留此標頭與推廣資訊。
#  免責聲明：本工具僅供合法用途（自建代理、企業內網加速、跨境辦公等），
#            請自行確認並遵守你所在地區的法律法規。
# =============================================================================
#
#  一鍵安裝（免下載）
#    bash <(curl -fsSL https://raw.githubusercontent.com/NatShiftN/xui-shield/main/xui-shield.sh)
#
#  安裝後
#    xui-shield                          # 一鍵：安裝面板 + Reality 節點 + 防火牆 + 備份
#    xui-shield --status                 # 查看目前狀態
#    xui-shield --firewall-only          # 只重新套用防火牆
#    xui-shield --backup-only            # 立即手動備份
#    xui-shield --help                   # 全部參數
#
#  設計原則
#    1. 不會鎖死你的 SSH：只新增規則、不 reset，逐個 SSH port 放行，還有 15 分鐘
#       自動回滾計時器（需經你確認才會保留）。
#    2. 每一步都可重複執行（idempotent），不會重新安裝、不會覆蓋你原有節點。
#    3. 出錯一定會告訴你錯在哪裡，並將完整日誌留在 /var/log/xui-shield.log。
# =============================================================================

set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
SCRIPT_NAME="xui-shield"

# ---------------------------------------------------------------------------
# 一鍵安裝 / 自我安裝
# 分叉（fork）後請把 SELF_URL 改成你自己的 raw 網址
# ---------------------------------------------------------------------------
SELF_PATH="/usr/local/bin/xui-shield"
SELF_URL="https://raw.githubusercontent.com/NatShiftN/xui-shield/main/xui-shield.sh"
SELF_URL_FALLBACK="https://cdn.jsdelivr.net/gh/NatShiftN/xui-shield@main/xui-shield.sh"
INSTALL_CMD="bash <(curl -fsSL ${SELF_URL})"
SELF_CMD="xui-shield"
STREAMED=0
case "${BASH_SOURCE[0]:-$0}" in
    /dev/fd/* | /proc/self/fd/*) STREAMED=1 ;;
esac

# ---------------------------------------------------------------------------
# 品牌資料（想修改推廣內容，只需要修改這一組）
# ---------------------------------------------------------------------------
BRAND_NAME="NatShift-N"
BRAND_TG="@NatShift"
BRAND_TG_URL="https://t.me/NatShift"
BRAND_SITE="hkvps.xyz"
BRAND_SITE_URL="https://hkvps.xyz"

# ---------------------------------------------------------------------------
# 固定路徑
# ---------------------------------------------------------------------------
CONF_DIR="/etc/xui-shield"
CONF_FILE="${CONF_DIR}/config.env"
STATE_DIR="/var/lib/xui-shield"
LOG_FILE="/var/log/xui-shield.log"
BACKUP_HELPER="/usr/local/sbin/xui-shield-backup"
FW_GUARD_BIN="/usr/local/sbin/xui-shield-fw-guard"
FW_CONFIRM_MARK="/run/xui-shield-fw-ok"
SYSCTL_FILE="/etc/sysctl.d/99-xui-shield.conf"
F2B_JAIL_FILE="/etc/fail2ban/jail.d/90-xui-shield.local"
XUI_MAIN="/usr/local/x-ui"
XUI_BIN="${XUI_MAIN}/x-ui"
XUI_DB="/etc/x-ui/x-ui.db"
XUI_SERVICE="x-ui"

# ---------------------------------------------------------------------------
# 預設值（可被 config.env / CLI 覆蓋）
# ---------------------------------------------------------------------------
PANEL_PORT=""
PANEL_PATH=""
PANEL_USER=""
PANEL_PASS=""
PANEL_LOCAL=0
PANEL_TLS=1
PANEL_DOMAIN=""
API_TOKEN=""

REALITY_PORT="443"
REALITY_SNI="www.microsoft.com"
REALITY_UUID=""
REALITY_PRIV=""
REALITY_PUB=""
REALITY_SID=""
REALITY_SUBID=""
REALITY_REMARK=""

BACKUP_ENABLE=1
BACKUP_DIR="/var/backups/x-ui"
BACKUP_TIME="04:30"
BACKUP_KEEP="14"
TG_BOT_TOKEN=""
TG_CHAT_ID=""

FIREWALL_ENABLE=1
FAIL2BAN_ENABLE=1
BBR_ENABLE=1
FW_BACKEND=""
SSH_PORTS=""

ACTION="install"
ASSUME_YES=0
FORCE_REINSTALL=0
FORCE_PANEL_RESET=0
RESTORE_FILE=""
DEBUG=0
CONFIG_LOADED=0
FRESH_INSTALL=0
PANEL_ADOPTED=0
PUBLIC_IP=""
PUBLIC_HOST="${XUI_PUBLIC_HOST:-}"
REALITY_PUBLIC_PORT="${XUI_PUBLIC_PORT:-}"
PANEL_PUBLIC_PORT="${XUI_PANEL_PUBLIC_PORT:-}"
LOCAL_IP=""
NAT_SUSPECT=0
FAIL_STAGE="preflight"
CLIENT_LINK_FILE="/root/xui-shield-client.txt"
CLIENT_LINK=""
COOKIE_JAR=""
CSRF_TOKEN=""

# ---------------------------------------------------------------------------
# 顏色（FORCE_COLOR=1 可強制開啟，NO_COLOR=1 可強制關閉）
# ---------------------------------------------------------------------------
USE_COLOR=0
if [[ -z ${NO_COLOR:-} ]]; then
    if [[ -n ${FORCE_COLOR:-} ]]; then
        USE_COLOR=1
    elif [[ -t 1 && ${TERM:-dumb} != "dumb" ]]; then
        USE_COLOR=1
    fi
fi

if ((USE_COLOR == 1)); then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
    C_WHITE=$'\033[97m'
    C_GREY=$'\033[38;5;245m'
    C_NEON=$'\033[38;5;51m'
    C_GOLD=$'\033[38;5;220m'
else
    C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE=""
    C_CYAN="" C_WHITE="" C_GREY="" C_NEON="" C_GOLD=""
fi

# ---------------------------------------------------------------------------
# 基本輸出 / 日誌
# ---------------------------------------------------------------------------
log_line() {
    local line="$*"
    [[ -n ${line} ]] || return 0
    if [[ -w ${LOG_FILE} || -w $(dirname "${LOG_FILE}") ]]; then
        printf '%s [%s] %s\n' "$(date '+%F %T')" "${SCRIPT_NAME}" "${line}" \
            >>"${LOG_FILE}" 2>/dev/null || true
    fi
}

say()  { printf '%s\n' "$*"; log_line "$*"; }
info() { printf '  %s•%s %s\n' "${C_BLUE}" "${C_RESET}" "$*"; log_line "INFO  $*"; }
ok()   { printf '  %s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; log_line "OK    $*"; }
warn() { printf '  %s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*"; log_line "WARN  $*"; }
err()  { printf '  %sx%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; log_line "ERR   $*"; }
dbg()  { if [[ ${DEBUG} -eq 1 ]]; then printf '%s[dbg] %s%s\n' "${C_GREY}" "$*" "${C_RESET}" >&2; fi; }

hr() {
    local char=${1:-─} width=${2:-68} bar
    printf -v bar '%*s' "${width}" ''
    bar=${bar// /${char}}
    printf '%s%s%s\n' "${C_GREY}" "${bar}" "${C_RESET}"
}

stage() {
    # stage <key> <title>
    FAIL_STAGE="$1"
    printf '\n%s%s▌%s %s%s%s\n' "${C_BOLD}" "${C_CYAN}" "${C_RESET}" \
        "${C_BOLD}${C_WHITE}" "$2" "${C_RESET}"
    hr "─" 68
    log_line "== STAGE ${1}: ${2}"
}

# ---------------------------------------------------------------------------
# 失敗時的「痛點推銷」——這是轉化率最高的環節，不要刪除
# ---------------------------------------------------------------------------
print_failure_pitch() {
    local stage_name="${1:-unknown}" reason=""
    case "${stage_name}" in
        packages) reason="套件安裝失敗，通常是軟件源（mirror）失效、DNS 解析異常、或者系統版本太舊。" ;;
        install)  reason="3x-ui 安裝失敗，最常見的是 GitHub 被阻、443/80 被其他服務佔用、或者主機本身已有殘留的舊版 x-ui。" ;;
        panel)    reason="面板無法啟動，通常是端口衝突、SQLite 權限、SELinux/AppArmor 攔截，或者 systemd 單元損壞。" ;;
        reality)  reason="節點建立失敗，通常是 Reality 目標站（SNI）連不上、端口被封、或者面板 API 版本不匹配。" ;;
        firewall) reason="防火牆規則寫入失敗。這一步最危險——隨意嘗試很容易導致 SSH 也被鎖死，之後只能進入救援模式。" ;;
        fail2ban) reason="Fail2ban 與系統日誌後端（systemd-journal / rsyslog）衝突，或者 nftables 未安裝。" ;;
        backup)   reason="備份失敗，通常是磁盤空間不足、sqlite3 鎖定、或者備份目錄權限有問題。" ;;
        sysctl)   reason="內核參數不支援。OpenVZ / LXC 這類容器通常無法修改 BBR 和 TCP 參數。" ;;
        verify)   reason="部署完成但自我檢查未通過，通常是端口未監聽、服務啟動超時、或者雲廠商安全組未放行。" ;;
        *)        reason="執行過程中出現未預期的錯誤。" ;;
    esac

    printf '\n'
    printf '%s%s╔══════════════════════════════════════════════════════════════════╗%s\n' \
        "${C_BOLD}" "${C_RED}" "${C_RESET}"
    printf '%s%s║%s  %s✖  這一步停住了：%s%s\n' "${C_BOLD}" "${C_RED}" "${C_RESET}" \
        "${C_RED}" "${C_RESET}" "${stage_name}"
    printf '%s%s╚══════════════════════════════════════════════════════════════════╝%s\n' \
        "${C_BOLD}" "${C_RED}" "${C_RESET}"
    printf '\n  %s可能原因%s\n' "${C_BOLD}" "${C_RESET}"
    printf '    %s\n' "${reason}"
    printf '\n  %s自己處理不了？這正是我們的專業範圍。%s\n' "${C_BOLD}${C_YELLOW}" "${C_RESET}"
    printf '    %s·%s 香港動態 IP NAT VPS：每天自動更換 IP，PVE / KVM 全虛擬化（不是容器）\n' "${C_CYAN}" "${C_RESET}"
    printf '    %s·%s 3x-ui / Xray 代部署、修復、遷移（保留原有節點和用戶）\n' "${C_CYAN}" "${C_RESET}"
    printf '    %s·%s 已被封 IP / 端口 / SNI？可配合 DDNS + 每日換 IP 方案\n' "${C_CYAN}" "${C_RESET}"
    printf '\n  %s請將上面的錯誤與日誌貼給我們，可以幫你先做免費初步判斷：%s\n' \
        "${C_DIM}" "${C_RESET}"
    printf '    %s日誌：%s\n' "${C_DIM}" "${LOG_FILE}"
    printf '    %sTelegram：%s%s   %s%s\n' \
        "${C_DIM}" "${C_RESET}${C_BOLD}${C_NEON}" "${BRAND_TG}" \
        "${C_BOLD}${C_NEON}" "${BRAND_TG_URL}${C_RESET}"
    printf '    %sVPS 官網：%s%s%s\n' "${C_DIM}" "${C_RESET}${C_BOLD}${C_GOLD}" \
        "${BRAND_SITE_URL}" "${C_RESET}"
    printf '\n'
}

die() {
    local message="$*"
    trap - ERR
    err "${message}"
    print_failure_pitch "${FAIL_STAGE}"
    exit 1
}

on_error() {
    local ec=$1 line=$2 cmd=$3
    trap - ERR
    set +e
    # 不要將密碼 / token 寫入終端或日誌
    local safe_cmd="${cmd}"
    [[ -n ${PANEL_PASS:-} ]] && safe_cmd=${safe_cmd//${PANEL_PASS}/<redacted>}
    [[ -n ${TG_BOT_TOKEN:-} ]] && safe_cmd=${safe_cmd//${TG_BOT_TOKEN}/<redacted>}
    [[ -n ${API_TOKEN:-} ]] && safe_cmd=${safe_cmd//${API_TOKEN}/<redacted>}
    err "第 ${line} 行執行失敗（exit ${ec}）：${safe_cmd}"
    print_failure_pitch "${FAIL_STAGE}"
    exit "${ec}"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# 結尾彩色廣告看板
# ---------------------------------------------------------------------------
print_ad_board() {
    local bar
    printf -v bar '%*s' 70 ''
    bar=${bar// /═}

    printf '\n'
    printf '%s╔%s╗%s\n' "${C_CYAN}" "${bar}" "${C_RESET}"
    printf '%s║%s  %s%s✅  部署完成 · 面板和防禦已經上線%s\n' "${C_CYAN}" "${C_RESET}" \
        "${C_BOLD}" "${C_GREEN}" "${C_RESET}"
    printf '%s╚%s╝%s\n' "${C_CYAN}" "${bar}" "${C_RESET}"

    printf '\n%s  ┌─ 還想再上一層？%s\n' "${C_BOLD}${C_GOLD}" "${C_RESET}"
    printf '  │  %s·%s 節點被針對、IP 被封、晚高峰卡頓到無法使用？\n' "${C_YELLOW}" "${C_RESET}"
    printf '  │    我們的%s香港動態 IP NAT VPS%s：每天自動更換 IP，PVE / KVM 全虛擬化（不是容器）。\n' \
        "${C_BOLD}${C_WHITE}" "${C_RESET}"
    printf '  │    共享 IPv4 + 端口映射，成本更低；BBR + NAT keepalive，減少空閒斷線。\n'
    printf '  │  %s·%s 想增加節點、做負載均衡、或者交接給團隊？可以代維運。\n' "${C_YELLOW}" "${C_RESET}"
    printf '  │  %s·%s 面板想更換真憑證、加入 CDN、接入訂閱系統？一次完成。\n' "${C_YELLOW}" "${C_RESET}"
    printf '  └─\n'

    printf '\n'
    printf '   %s🌐  VPS 官網%s   %s%s%s\n' "${C_BOLD}${C_WHITE}" "${C_RESET}" \
        "${C_BOLD}${C_GOLD}" "${BRAND_SITE_URL}" "${C_RESET}"
    printf '   %s✈️   Telegram%s   %s%s%s  %s(%s)%s\n' "${C_BOLD}${C_WHITE}" "${C_RESET}" \
        "${C_BOLD}${C_NEON}" "${BRAND_TG_URL}" "${C_RESET}" "${C_DIM}" "${BRAND_TG}" "${C_RESET}"
    printf '   %s🛠️   報錯 / 代部署%s 貼上日誌並說明「用了 xui-shield」，優先處理。\n' \
        "${C_BOLD}${C_WHITE}" "${C_RESET}"
    printf '\n'
    printf '%s   ──────────────────────────────────────────────────────────────%s\n' \
        "${C_GREY}" "${C_RESET}"
    printf '%s   覺得好用？幫我轉發給一位有需要的朋友，就是最好的支持。%s\n' \
        "${C_DIM}" "${C_RESET}"
    printf '%s   ──────────────────────────────────────────────────────────────%s\n' \
        "${C_GREY}" "${C_RESET}"
    printf '\n'
}

# ---------------------------------------------------------------------------
# 用法
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
${C_BOLD}xui-shield${C_RESET} v${SCRIPT_VERSION} — 3x-ui 一鍵抗封鎖 + 自動防火牆 + 每日備份
${C_DIM}${BRAND_SITE}  ·  ${BRAND_TG}${C_RESET}

${C_BOLD}安裝（免下載）${C_RESET}
  ${INSTALL_CMD}
  # 安裝後可直接使用 xui-shield

${C_BOLD}用法${C_RESET}
  ${SELF_CMD} [選項]

${C_BOLD}動作${C_RESET}
  （無參數）            完整部署：面板 + VLESS-Reality 節點 + 防火牆 + Fail2ban + BBR + 每日備份
  --status              查看目前狀態（面板、節點、防火牆、備份、BBR）
  --check               只做環境檢查，不改動系統（dry-run）
  --firewall-only       只重新套用防火牆 + Fail2ban 規則
  --backup-only         立即手動備份一次
  --restore FILE        由備份檔還原面板資料庫
  --confirm-firewall    確認保留防火牆（取消 15 分鐘自動回滾）
  --uninstall           移除本腳本新增的定時器 / 防火牆規則 / Fail2ban 設定（保留面板和資料）

${C_BOLD}面板${C_RESET}
  --panel-port N        面板端口（預設隨機 10000-60000）
  --panel-domain D      用域名訪問面板（需自行將域名指向本機；憑證仍為自簽）
  --no-panel-tls        面板只用 HTTP（不建議，除非你已經有反向代理）
  --panel-tls           面板使用 HTTPS（預設，自簽憑證）
  --local-panel         面板只綁定 127.0.0.1，用 SSH 隧道訪問（最安全）
  --public-panel        面板改回綁定 0.0.0.0（方便直接開啟瀏覽器）
  --force-panel-reset   重設面板帳號 / 密碼 / 端口 / 路徑（會導致舊連結失效）

${C_BOLD}節點${C_RESET}
  --port N              Reality 監聽端口（預設 443，被佔用時自動改用高位端口）
  --sni HOST            Reality 偽裝目標（預設 www.microsoft.com）

${C_BOLD}NAT VPS / 動態 IP${C_RESET}
  --public-host HOST    對外訪問用的域名或 IP（每天換 IP 強烈建議填 DDNS 域名）
  --public-port N       Reality 對外映射端口（NAT VPS 用；預設等於內網端口）
  --panel-public-port N 面板對外映射端口（NAT VPS 用；預設等於內網端口）

${C_BOLD}防火牆 / 備份${C_RESET}
  --no-firewall         不改防火牆
  --no-fail2ban         不安裝 Fail2ban
  --no-bbr              不改 BBR / 內核參數
  --no-backup           不設定每日備份
  --backup-dir DIR      備份目錄（預設 /var/backups/x-ui）
  --backup-time HH:MM   每日備份時間（預設 04:30，伺服器本地時間）
  --keep N              保留天數（預設 14）
  --tg-token TOKEN      Telegram Bot Token（備份自動上傳到 TG）
  --tg-chat ID          Telegram Chat ID

${C_BOLD}其他${C_RESET}
  -y, --yes             不詢問，直接執行
  --reinstall           強制重新安裝 3x-ui（資料庫會保留）
  --debug               顯示除錯資訊
  -h, --help            顯示本說明
  -V, --version         顯示版本

${C_BOLD}常用例子${C_RESET}
  ${SELF_CMD}                              # 最常用：一鍵全自動
  ${SELF_CMD} --port 8443 --sni www.apple.com
  ${SELF_CMD} --public-host node.example.com --public-port 24567 --panel-public-port 24568
                                       # NAT VPS + DDNS：客戶端用域名:24567
  ${SELF_CMD} --local-panel            # 面板只聽 localhost，之後：
                                       # ssh -L 8080:127.0.0.1:<面板端口> root@<IP>
  ${SELF_CMD} --backup-only            # 換機前手動備份
  ${SELF_CMD} --restore /var/backups/x-ui/xui-shield-backup-20250101-043000.tar.gz

${C_DIM}提示：本腳本只會「新增」防火牆規則，不會 reset。修改防火牆後有 15 分鐘自動回滾，
      確認 SSH 正常後執行 --confirm-firewall（或按提示按 Enter）即可保留。${C_RESET}
EOF
}

# ---------------------------------------------------------------------------
# 參數解析
# ---------------------------------------------------------------------------
need_value() {
    [[ -n ${2:-} ]] || { err "參數 $1 需要一個值"; exit 2; }
}

parse_args() {
    while (($#)); do
        case "$1" in
            -h | --help) usage; exit 0 ;;
            -V | --version) printf '%s %s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"; exit 0 ;;
            --status) ACTION="status" ;;
            --check | --dry-run) ACTION="check" ;;
            --firewall-only) ACTION="firewall" ;;
            --backup-only) ACTION="backup" ;;
            --backup-run) ACTION="backup-run" ;;
            --confirm-firewall) ACTION="confirm-fw" ;;
            --uninstall) ACTION="uninstall" ;;
            --restore)
                need_value "$1" "${2:-}"
                ACTION="restore"
                RESTORE_FILE="$2"
                shift
                ;;
            --port)
                need_value "$1" "${2:-}"
                REALITY_PORT="$2"
                shift
                ;;
            --sni)
                need_value "$1" "${2:-}"
                REALITY_SNI="$2"
                shift
                ;;
            --panel-port)
                need_value "$1" "${2:-}"
                PANEL_PORT="$2"
                shift
                ;;
            --panel-domain)
                need_value "$1" "${2:-}"
                PANEL_DOMAIN="$2"
                shift
                ;;
            --public-host)
                need_value "$1" "${2:-}"
                PUBLIC_HOST="$2"
                shift
                ;;
            --public-port)
                need_value "$1" "${2:-}"
                REALITY_PUBLIC_PORT="$2"
                shift
                ;;
            --panel-public-port)
                need_value "$1" "${2:-}"
                PANEL_PUBLIC_PORT="$2"
                shift
                ;;
            --no-panel-tls) PANEL_TLS=0 ;;
            --panel-tls) PANEL_TLS=1 ;;
            --local-panel) PANEL_LOCAL=1 ;;
            --public-panel) PANEL_LOCAL=0 ;;
            --force-panel-reset) FORCE_PANEL_RESET=1 ;;
            --no-firewall) FIREWALL_ENABLE=0 ;;
            --no-fail2ban) FAIL2BAN_ENABLE=0 ;;
            --no-bbr) BBR_ENABLE=0 ;;
            --no-backup) BACKUP_ENABLE=0 ;;
            --backup-dir)
                need_value "$1" "${2:-}"
                BACKUP_DIR="$2"
                shift
                ;;
            --backup-time)
                need_value "$1" "${2:-}"
                BACKUP_TIME="$2"
                shift
                ;;
            --keep)
                need_value "$1" "${2:-}"
                BACKUP_KEEP="$2"
                shift
                ;;
            --tg-token)
                need_value "$1" "${2:-}"
                TG_BOT_TOKEN="$2"
                shift
                ;;
            --tg-chat)
                need_value "$1" "${2:-}"
                TG_CHAT_ID="$2"
                shift
                ;;
            -y | --yes) ASSUME_YES=1 ;;
            --reinstall) FORCE_REINSTALL=1 ;;
            --debug) DEBUG=1 ;;
            --)
                shift
                break
                ;;
            *)
                err "未知參數：$1"
                printf '試下 %s --help\n' "${SELF_CMD}" >&2
                exit 2
                ;;
        esac
        shift
    done
}

# ---------------------------------------------------------------------------
# 通用工具
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        err "需要 root 權限。請用 root 執行（例如先執行 sudo -i）。"
        exit 1
    fi
}

# 把目前腳本安裝到 /usr/local/bin/xui-shield，之後可直接用 xui-shield 命令
install_self() {
    [[ ${EUID} -eq 0 ]] || return 0

    local src="${BASH_SOURCE[0]:-$0}"
    if ((STREAMED == 0)) && [[ -f ${src} ]]; then
        src=$(readlink -f "${src}" 2>/dev/null || printf '%s' "${src}")
        if [[ ${src} != "${SELF_PATH}" ]]; then
            if install -m 755 "${src}" "${SELF_PATH}" 2>/dev/null; then
                ok "已安裝命令：${SELF_CMD}"
            else
                warn "無法安裝命令到 ${SELF_PATH}，仍可繼續使用本次執行。"
            fi
        fi
        return 0
    fi

    # 由 curl 直接執行：抓一份到本機，令後續 --status / --confirm-firewall 可用
    if [[ ! -x ${SELF_PATH} ]] || ((STREAMED == 1)); then
        info "安裝命令列工具到 ${SELF_PATH} …"
        local tmp="${SELF_PATH}.tmp.$$" url
        for url in "${SELF_URL}" "${SELF_URL_FALLBACK}"; do
            if curl -fsSL --max-time 60 "${url}" -o "${tmp}" &&
                chmod 755 "${tmp}" &&
                mv -f "${tmp}" "${SELF_PATH}"; then
                ok "已安裝命令：${SELF_CMD}"
                return 0
            fi
        done
        rm -f "${tmp}" 2>/dev/null || true
        warn "無法安裝 ${SELF_CMD} 命令；可繼續使用本次執行，或重新貼上一鍵指令。"
    fi
}

rand_alnum() {
    local n="$1" s
    s=$(openssl rand -base64 $(((n * 3) / 4 + 8)) 2>/dev/null | tr -dc 'A-Za-z0-9')
    printf '%s' "${s:0:n}"
}

rand_hex() {
    local s
    s=$(openssl rand -hex "$1" 2>/dev/null)
    printf '%s' "${s}"
}

public_ipv4() {
    local url ip
    for url in "https://api4.ipify.org" "https://ipv4.icanhazip.com" \
        "https://ifconfig.me/ip" "https://4.ident.me"; do
        ip=$(curl -4 -fsS --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]') || true
        if [[ ${ip} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            printf '%s' "${ip}"
            return 0
        fi
    done
    return 1
}

private_ipv4() {
    ip -4 route get 1.1.1.1 2>/dev/null |
        awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}'
}

# ---------------------------------------------------------------------------
# 對外訪問地址（NAT VPS：內網端口 ≠ 對外端口）
# ---------------------------------------------------------------------------
public_host() {
    printf '%s' "${PUBLIC_HOST:-${PANEL_DOMAIN:-${PUBLIC_IP:-127.0.0.1}}}"
}

panel_host() {
    printf '%s' "${PANEL_DOMAIN:-$(public_host)}"
}

reality_public_port() {
    printf '%s' "${REALITY_PUBLIC_PORT:-${REALITY_PORT}}"
}

panel_public_port() {
    printf '%s' "${PANEL_PUBLIC_PORT:-${PANEL_PORT}}"
}

nat_mode() {
    [[ -n ${REALITY_PUBLIC_PORT} && ${REALITY_PUBLIC_PORT} != "${REALITY_PORT}" ]] ||
        [[ -n ${PANEL_PUBLIC_PORT} && ${PANEL_PUBLIC_PORT} != "${PANEL_PORT}" ]]
}

port_in_use() {
    local p="$1"
    if have ss; then
        ss -H -ltn 2>/dev/null | awk -v pat=":${p}$" '$4 ~ pat { found = 1 } END { exit !found }'
        return
    fi
    if have netstat; then
        netstat -ltn 2>/dev/null | awk -v pat=":${p}$" '$4 ~ pat { found = 1 } END { exit !found }'
        return
    fi
    return 1
}

port_owner() {
    local p="$1"
    have ss || return 0
    ss -H -ltnp 2>/dev/null | awk -v pat=":${p}$" '$4 ~ pat { print $NF; exit }'
}

wait_port() {
    local p="$1" timeout="${2:-30}" i=0
    while ((i < timeout)); do
        if port_in_use "${p}"; then return 0; fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

wait_http() {
    local url="$1" timeout="${2:-30}" i=0 code
    while ((i < timeout)); do
        code=$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 5 "${url}" 2>/dev/null) || code="000"
        if [[ ${code} != "000" ]]; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

confirm() {
    local prompt="$1" default="${2:-n}" ans
    if ((ASSUME_YES == 1)); then
        ok "${prompt} → 自動確認（--yes）"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        warn "${prompt} → 非互動環境，預設跳過"
        return 1
    fi
    if [[ ${default} == "y" ]]; then
        read -r -p "${prompt} [Y/n]: " ans || ans=""
        [[ ${ans:-y} =~ ^[Yy]$ ]]
    else
        read -r -p "${prompt} [y/N]: " ans || ans=""
        [[ ${ans:-n} =~ ^[Yy]$ ]]
    fi
}

banner() {
    printf '\n%s%s' "${C_BOLD}" "${C_CYAN}"
    cat <<'EOF'
  ╔════════════════════════════════════════════════════════════════════╗
  ║   X U I - S H I E L D
  ║   3x-ui 一鍵抗封鎖 · 自動防火牆 · 每日備份
  ╚════════════════════════════════════════════════════════════════════╝
EOF
    printf '%s' "${C_RESET}"
    printf '  %sv%s  %s%s · %s%s\n' "${C_DIM}" "${SCRIPT_VERSION}" "${C_RESET}" \
        "${C_GREY}${BRAND_NAME}" "${BRAND_SITE}" "${C_RESET}"
}

# ---------------------------------------------------------------------------
# 系統偵測
# ---------------------------------------------------------------------------
detect_os() {
    if [[ ! -r /etc/os-release ]]; then
        FAIL_STAGE="preflight"
        die "無法讀取 /etc/os-release，無法識別系統。"
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-}"
    OS_PRETTY="${PRETTY_NAME:-${OS_ID} ${OS_VERSION}}"

    case "${OS_ID}" in
        debian | ubuntu | raspbian | armbian | linuxmint | pop | neon | kali)
            PKG="apt"
            ;;
        centos | rhel | rocky | almalinux | oracle | ol | fedora | amzn)
            if have dnf; then PKG="dnf"; else PKG="yum"; fi
            ;;
        opensuse* | sles | sled)
            PKG="zypper"
            ;;
        *)
            FAIL_STAGE="preflight"
            die "暫不支援 ${OS_PRETTY}。建議用 Debian 12 / Ubuntu 22.04 或以上。"
            ;;
    esac
    ARCH="$(uname -m)"
}

detect_virt() {
    VIRT="unknown"
    if have systemd-detect-virt; then
        VIRT=$(systemd-detect-virt 2>/dev/null || true)
        [[ -n ${VIRT} ]] || VIRT="none"
    elif [[ -f /.dockerenv ]]; then
        VIRT="docker"
    fi
}

pkg_refresh() {
    case "${PKG}" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get update -qq ||
                DEBIAN_FRONTEND=noninteractive apt-get update -qq
            ;;
        dnf) dnf makecache -y -q || true ;;
        yum) yum makecache -y -q || true ;;
        zypper) zypper --non-interactive refresh || true ;;
    esac
}

pkg_install() {
    [[ $# -gt 0 ]] || return 0
    case "${PKG}" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" "$@"
            ;;
        dnf) dnf install -y -q "$@" ;;
        yum) yum install -y -q "$@" ;;
        zypper) zypper --non-interactive install -y "$@" ;;
        *) return 1 ;;
    esac
}

pkg_installed() {
    case "${PKG}" in
        apt) dpkg -s "$1" >/dev/null 2>&1 ;;
        dnf | yum) rpm -q "$1" >/dev/null 2>&1 ;;
        zypper) rpm -q "$1" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# SSH 端口偵測（防火牆生命線，寧可多放行也不要遺漏）
# ---------------------------------------------------------------------------
detect_ssh_ports() {
    local -a found=()
    local p

    if [[ -n ${SSH_CONNECTION:-} ]]; then
        p=$(awk '{print $4}' <<<"${SSH_CONNECTION}")
        [[ ${p} =~ ^[0-9]+$ ]] && found+=("${p}")
    fi

    if have sshd; then
        while IFS= read -r p; do
            [[ ${p} =~ ^[0-9]+$ ]] && found+=("${p}")
        done < <(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }')
    fi

    for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
        [[ -r ${f} ]] || continue
        while IFS= read -r p; do
            [[ ${p} =~ ^[0-9]+$ ]] && found+=("${p}")
        done < <(awk 'tolower($1) == "port" { print $2 }' "${f}" 2>/dev/null)
    done

    if ((${#found[@]} == 0)); then
        found=(22)
    fi

    SSH_PORTS=$(printf '%s\n' "${found[@]}" | awk '!seen[$0]++' | paste -sd, -)
    [[ -n ${SSH_PORTS} ]] || SSH_PORTS="22"
    dbg "SSH ports: ${SSH_PORTS}"
}

# ---------------------------------------------------------------------------
# 設定檔
# ---------------------------------------------------------------------------
load_config() {
    if [[ -r ${CONF_FILE} ]]; then
        # shellcheck disable=SC1090
        . "${CONF_FILE}"
        CONFIG_LOADED=1
        dbg "loaded config ${CONF_FILE}"
    fi
    # 環境變數優先，方便一鍵安裝時直接帶入 NAT 參數
    PUBLIC_HOST="${XUI_PUBLIC_HOST:-${PUBLIC_HOST}}"
    REALITY_PUBLIC_PORT="${XUI_PUBLIC_PORT:-${REALITY_PUBLIC_PORT}}"
    PANEL_PUBLIC_PORT="${XUI_PANEL_PUBLIC_PORT:-${PANEL_PUBLIC_PORT}}"
}

save_config() {
    install -d -m 700 "${CONF_DIR}" 2>/dev/null || true
    local prev_umask
    prev_umask=$(umask)
    umask 077
    {
        printf 'PANEL_PORT=%q\n' "${PANEL_PORT}"
        printf 'PANEL_PATH=%q\n' "${PANEL_PATH}"
        printf 'PANEL_USER=%q\n' "${PANEL_USER}"
        printf 'PANEL_PASS=%q\n' "${PANEL_PASS}"
        printf 'PANEL_LOCAL=%q\n' "${PANEL_LOCAL}"
        printf 'PANEL_TLS=%q\n' "${PANEL_TLS}"
        printf 'PANEL_DOMAIN=%q\n' "${PANEL_DOMAIN}"
        printf 'PANEL_ADOPTED=%q\n' "${PANEL_ADOPTED}"
        printf 'REALITY_PORT=%q\n' "${REALITY_PORT}"
        printf 'REALITY_SNI=%q\n' "${REALITY_SNI}"
        printf 'REALITY_UUID=%q\n' "${REALITY_UUID}"
        printf 'REALITY_PRIV=%q\n' "${REALITY_PRIV}"
        printf 'REALITY_PUB=%q\n' "${REALITY_PUB}"
        printf 'REALITY_SID=%q\n' "${REALITY_SID}"
        printf 'REALITY_SUBID=%q\n' "${REALITY_SUBID}"
        printf 'REALITY_REMARK=%q\n' "${REALITY_REMARK}"
        printf 'BACKUP_DIR=%q\n' "${BACKUP_DIR}"
        printf 'BACKUP_TIME=%q\n' "${BACKUP_TIME}"
        printf 'BACKUP_KEEP=%q\n' "${BACKUP_KEEP}"
        printf 'TG_BOT_TOKEN=%q\n' "${TG_BOT_TOKEN}"
        printf 'TG_CHAT_ID=%q\n' "${TG_CHAT_ID}"
        printf 'FW_BACKEND=%q\n' "${FW_BACKEND}"
        printf 'SSH_PORTS=%q\n' "${SSH_PORTS}"
        printf 'PUBLIC_IP=%q\n' "${PUBLIC_IP}"
        printf 'PUBLIC_HOST=%q\n' "${PUBLIC_HOST}"
        printf 'REALITY_PUBLIC_PORT=%q\n' "${REALITY_PUBLIC_PORT}"
        printf 'PANEL_PUBLIC_PORT=%q\n' "${PANEL_PUBLIC_PORT}"
        printf 'INSTALLED_AT=%q\n' "$(date '+%F %T')"
    } >"${CONF_FILE}"
    umask "${prev_umask}"
    chmod 600 "${CONF_FILE}"
    chown root:root "${CONF_FILE}" 2>/dev/null || true
    ok "設定已儲存：${CONF_FILE}（權限 600）"
}

# ---------------------------------------------------------------------------
# 環境檢查
# ---------------------------------------------------------------------------
preflight() {
    stage "preflight" "環境檢查"
    detect_os
    detect_virt
    detect_ssh_ports

    ok "系統：${OS_PRETTY}（${ARCH}，${VIRT}）"
    ok "套件管理器：${PKG}"
    ok "SSH 端口：${SSH_PORTS}"

    if [[ ! -d /run/systemd/system ]]; then
        die "這個系統沒有 systemd（或者未完成開機），3x-ui 服務和定時備份都需要 systemd。"
    fi

    local mem_mb disk_mb
    mem_mb=$(awk '/MemTotal/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null || echo 0)
    disk_mb=$(df -Pm / 2>/dev/null | awk 'NR == 2 { print $4 }' || echo 0)
    if ((mem_mb < 200)); then
        warn "記憶體只有 ${mem_mb}MB，建議 512MB 以上，否則面板可能被 OOM 殺掉。"
    else
        ok "記憶體：${mem_mb}MB　根分區剩餘：${disk_mb}MB"
    fi
    if ((disk_mb < 700)); then
        die "根分區只剩 ${disk_mb}MB，安裝 3x-ui + Xray 需要至少 700MB。請先清理磁盤空間。"
    fi

    if have timedatectl; then
        local sync
        sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
        if [[ ${sync} == "no" ]]; then
            warn "系統時間未同步。Reality 對時間偏差敏感，正在嘗試開啟 NTP …"
            timedatectl set-ntp true 2>/dev/null || true
        else
            ok "系統時間已同步"
        fi
    fi

    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' -I --max-time 10 https://raw.githubusercontent.com 2>/dev/null || echo 000)
    if [[ ${code} == "000" ]]; then
        FAIL_STAGE="install"
        die "無法連接 GitHub（raw.githubusercontent.com）。3x-ui 安裝檔在 GitHub，請先解決網絡或者設定代理。"
    fi
    ok "GitHub 連線正常（HTTP ${code}）"

    PUBLIC_IP=$(public_ipv4 || true)
    LOCAL_IP=$(private_ipv4 || true)
    if [[ -z ${PUBLIC_IP} ]]; then
        PUBLIC_IP="${LOCAL_IP}"
        warn "偵測不到公網 IPv4，暫用 ${PUBLIC_IP:-未知}。節點連結可能要用你實際 IP 替換。"
    else
        ok "公網 IPv4：${PUBLIC_IP}"
    fi

    if [[ -n ${PUBLIC_IP} && -n ${LOCAL_IP} && ${PUBLIC_IP} != "${LOCAL_IP}" ]]; then
        NAT_SUSPECT=1
        warn "偵測到內網 IP ${LOCAL_IP} 與公網 IP ${PUBLIC_IP} 不同，可能是 NAT VPS。"
        warn "NAT / 端口映射環境請加 --public-host、--public-port、--panel-public-port。"
    fi

    if [[ -x ${XUI_BIN} ]]; then
        FRESH_INSTALL=0
        local ver
        ver=$("${XUI_BIN}" -v 2>/dev/null | head -n1 || true)
        warn "偵測到已安裝 3x-ui（${ver:-版本未知}），會沿用現有資料庫，不會重新安裝。"
    else
        FRESH_INSTALL=1
        ok "未偵測到 3x-ui，將會全新安裝"
    fi

    if ((FIREWALL_ENABLE == 1)); then
        # 已經有 firewalld 正在運行就不要強行安裝 UFW，兩者一起開啟會衝突
        if have firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
            FW_BACKEND="firewalld"
        elif have ufw; then
            FW_BACKEND="ufw"
        elif have firewall-cmd; then
            FW_BACKEND="firewalld"
        else
            FW_BACKEND="ufw"
        fi
        dbg "firewall backend: ${FW_BACKEND}"
    fi

    install -d -m 700 "${STATE_DIR}" 2>/dev/null || true
    touch "${LOG_FILE}" 2>/dev/null || true
    ok "日誌：${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# 面板：安裝
# ---------------------------------------------------------------------------
INSTALLER_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh"

install_packages() {
    stage "packages" "安裝必要套件"

    pkg_refresh || die "軟件源更新失敗。請檢查 /etc/apt/sources.list 或 DNS 設定。"

    local -a base=(curl ca-certificates openssl tar jq)
    if [[ ${PKG} == "apt" ]]; then
        base+=(sqlite3 iproute2)
    else
        base+=(sqlite iproute)
        pkg_install epel-release >>"${LOG_FILE}" 2>&1 || true
    fi

    pkg_install "${base[@]}" >>"${LOG_FILE}" 2>&1 ||
        die "基礎套件安裝失敗（${base[*]}）。"

    for bin in curl openssl tar jq; do
        have "${bin}" || die "套件 ${bin} 安裝後仍然找不到，軟件源可能有問題。"
    done
    ok "基礎套件完成"

    if ((FAIL2BAN_ENABLE == 1)); then
        if ! pkg_installed fail2ban; then
            if [[ ${PKG} == "dnf" || ${PKG} == "yum" ]]; then
                pkg_install epel-release >>"${LOG_FILE}" 2>&1 || true
            fi
            pkg_install fail2ban >>"${LOG_FILE}" 2>&1 || warn "Fail2ban 安裝失敗，會跳過（可之後手動安裝）"
            # fail2ban 新版預設用 nftables 封鎖，缺 nft 會令 ban 失效
            pkg_install nftables >>"${LOG_FILE}" 2>&1 || true
        fi
        have fail2ban-client && ok "Fail2ban 已就緒" || FAIL2BAN_ENABLE=0
    fi

    if ((FIREWALL_ENABLE == 1)) && [[ ${FW_BACKEND} == "ufw" ]]; then
        if ! have ufw; then
            if [[ ${PKG} == "dnf" || ${PKG} == "yum" ]]; then
                pkg_install epel-release >>"${LOG_FILE}" 2>&1 || true
            fi
            pkg_install ufw >>"${LOG_FILE}" 2>&1 ||
                die "UFW 安裝失敗。防火牆是本次部署的核心，不會在沒有防火牆的情況下繼續。"
        fi
        have ufw && ok "UFW 已就緒"
    fi

    if ((FIREWALL_ENABLE == 1)) && [[ ${FW_BACKEND} == "firewalld" ]]; then
        have firewall-cmd || die "firewalld 未安裝，無法設定防火牆。"
        ok "firewalld 已就緒（稍後會先加規則再 reload）"
    fi
}

install_panel() {
    stage "install" "安裝 3x-ui 面板"

    if [[ -x ${XUI_BIN} ]] && ((FORCE_REINSTALL == 0)); then
        ok "已安裝，跳過安裝（用 --reinstall 可強制重新安裝，資料庫會保留）"
        return 0
    fi

    local installer="${WORKDIR}/3x-ui-install.sh"
    info "下載官方安裝器 …"
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 120 \
        -o "${installer}" "${INSTALLER_URL}" >>"${LOG_FILE}" 2>&1 ||
        die "下載 3x-ui 安裝器失敗。"

    grep -q 'install_x-ui' "${installer}" ||
        die "下載到的安裝器內容不像 3x-ui 官方腳本，已中止（安全起見）。"

    info "執行安裝器（非互動模式，約 1-3 分鐘）…"
    local rc=0
    XUI_NONINTERACTIVE=1 \
        XUI_DB_TYPE=sqlite \
        XUI_SSL_MODE=none \
        XUI_ENABLE_FAIL2BAN=false \
        XUI_PANEL_PORT="${PANEL_PORT}" \
        XUI_WEB_BASE_PATH="${PANEL_PATH}" \
        XUI_USERNAME="${PANEL_USER}" \
        XUI_PASSWORD="${PANEL_PASS}" \
        XUI_SERVER_IP="${PUBLIC_IP}" \
        bash "${installer}" </dev/null >>"${LOG_FILE}" 2>&1 || rc=$?

    if ((rc != 0)) || [[ ! -x ${XUI_BIN} ]]; then
        err "安裝器最後 25 行輸出："
        tail -n 25 "${LOG_FILE}" >&2 || true
        die "3x-ui 安裝失敗（exit ${rc}）。常見於端口衝突、殘留舊版、或 GitHub 下載逾時。"
    fi

    systemctl enable "${XUI_SERVICE}" >>"${LOG_FILE}" 2>&1 || true
    systemctl start "${XUI_SERVICE}" >>"${LOG_FILE}" 2>&1 || true
    FRESH_INSTALL=1
    local version
    version=$("${XUI_BIN}" -v 2>/dev/null | sed -n '1p' || true)
    ok "3x-ui 安裝完成（${version:-版本未知}）"
}

# ---------------------------------------------------------------------------
# 面板：帳號 / 端口 / 路徑
# ---------------------------------------------------------------------------
adopt_panel_settings() {
    local out port path listen
    out=$("${XUI_BIN}" setting -show true 2>/dev/null || true)
    port=$(awk -F': ' '/^port:/ { print $2; exit }' <<<"${out}")
    path=$(awk -F': ' '/^webBasePath:/ { print $2; exit }' <<<"${out}" | sed 's#^/*##')
    listen=$(awk -F': ' '/^listenIP:/ { print $2; exit }' <<<"${out}")
    [[ ${port} =~ ^[0-9]+$ ]] || die "無法讀取現有面板端口，請用 --force-panel-reset 重設。"
    PANEL_PORT="${port}"
    [[ -n ${path} ]] && PANEL_PATH="${path}"
    [[ ${listen} == "127.0.0.1" ]] && PANEL_LOCAL=1
    # 不知道原有密碼，不要在報告裡顯示一組假密碼
    PANEL_USER=""
    PANEL_PASS=""
    PANEL_ADOPTED=1
    ok "沿用現有面板：端口 ${PANEL_PORT}，路徑 /${PANEL_PATH}"
}

apply_panel_settings() {
    stage "panel" "設定面板帳號 / 端口 / 路徑"

    if ((FORCE_PANEL_RESET == 0)) && [[ ${FRESH_INSTALL} -eq 0 ]] &&
        { ((CONFIG_LOADED == 0)) || ((PANEL_ADOPTED == 1)); }; then
        adopt_panel_settings
        return 0
    fi

    [[ -n ${PANEL_PORT} ]] || die "面板端口為空。"
    [[ -n ${PANEL_PATH} ]] || PANEL_PATH=$(rand_hex 6)
    [[ -n ${PANEL_USER} ]] || PANEL_USER="ns$(rand_alnum 6)"
    [[ -n ${PANEL_PASS} ]] || PANEL_PASS=$(rand_alnum 24)

    # 端口被其他程式佔用時自動更改端口，避免面板無法啟動
    if port_in_use "${PANEL_PORT}" && ! port_owner "${PANEL_PORT}" | grep -qiE 'x-ui|xray'; then
        warn "面板端口 ${PANEL_PORT} 已被其他程式佔用，自動改用其他端口。"
        local i p
        for ((i = 0; i < 60; i++)); do
            p=$(((RANDOM % 50000) + 10000))
            [[ ${p} == "${REALITY_PORT}" ]] && continue
            if ! port_in_use "${p}"; then
                PANEL_PORT="${p}"
                break
            fi
        done
        ok "改用面板端口 ${PANEL_PORT}"
        if [[ -n ${PANEL_PUBLIC_PORT} ]]; then
            warn "面板對外端口 ${PANEL_PUBLIC_PORT} 原本映射到舊內網端口，請同步更新服務商映射。"
        fi
    fi

    info "寫入面板設定（帳號、端口 ${PANEL_PORT}、隨機路徑）…"
    "${XUI_BIN}" setting \
        -username "${PANEL_USER}" \
        -password "${PANEL_PASS}" \
        -port "${PANEL_PORT}" \
        -webBasePath "${PANEL_PATH}" >>"${LOG_FILE}" 2>&1 ||
        die "寫入面板設定失敗（x-ui setting）。"

    if ((PANEL_LOCAL == 1)); then
        "${XUI_BIN}" setting -listenIP 127.0.0.1 >>"${LOG_FILE}" 2>&1 ||
            warn "設定面板只監聽 127.0.0.1 失敗，請手動檢查。"
        ok "面板只綁定 127.0.0.1（需 SSH 隧道訪問）"
    else
        "${XUI_BIN}" setting -listenIP 0.0.0.0 >>"${LOG_FILE}" 2>&1 || true
    fi

    # 重新讀取，確認設定真的生效
    local out
    out=$("${XUI_BIN}" setting -show true 2>/dev/null || true)
    PANEL_PORT=$(awk -F': ' '/^port:/ { print $2; exit }' <<<"${out}")
    PANEL_PATH=$(awk -F': ' '/^webBasePath:/ { print $2; exit }' <<<"${out}" | sed 's#^/*##')
    [[ ${PANEL_PORT} =~ ^[0-9]+$ ]] || die "面板端口設定後讀取失敗。"
    PANEL_ADOPTED=0
    ok "面板帳號：${PANEL_USER}　端口：${PANEL_PORT}　路徑：/${PANEL_PATH}"
}

# ---------------------------------------------------------------------------
# 面板：HTTPS（自簽）
# ---------------------------------------------------------------------------
setup_panel_tls() {
    stage "panel" "面板 HTTPS（自簽憑證）"

    local dir="/etc/x-ui/cert" crt key san existing_cert
    install -d -m 700 "${dir}"
    crt="${dir}/panel.crt"
    key="${dir}/panel.key"
    existing_cert=""
    if [[ -x ${XUI_BIN} ]]; then
        existing_cert=$("${XUI_BIN}" setting -getCert true 2>/dev/null |
            awk -F': ' '/^cert:/ { print $2; exit }' | tr -d '[:space:]')
    fi

    if ((PANEL_TLS == 0)); then
        if [[ -n ${existing_cert} && -f ${existing_cert} ]]; then
            warn "面板已經設定了憑證，維持 HTTPS（強制 HTTP 會使面板 API 失效）。"
            PANEL_TLS=1
        else
            warn "已停用面板 TLS，面板會以 HTTP 明文傳輸密碼。除非你有反向代理，否則不建議。"
            return 0
        fi
    fi

    # 如果面板已經有可用憑證（例如用戶自己用 acme.sh 簽發完成），不要覆蓋它
    if ((FORCE_PANEL_RESET == 0)) && [[ ${FRESH_INSTALL} -eq 0 ]]; then
        if [[ -n ${existing_cert} && -f ${existing_cert} ]]; then
            ok "偵測到現有面板憑證，沿用：${existing_cert}"
            return 0
        fi
    fi

    if [[ -s ${crt} && -s ${key} ]]; then
        ok "憑證已存在，沿用 ${crt}"
    else
        san="IP:${PUBLIC_IP},IP:127.0.0.1,DNS:localhost"
        if [[ -n ${PUBLIC_HOST} && ${PUBLIC_HOST} != "${PUBLIC_IP}" ]]; then
            if [[ ${PUBLIC_HOST} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                san="IP:${PUBLIC_HOST},${san}"
            else
                san="DNS:${PUBLIC_HOST},${san}"
            fi
        fi
        if [[ -n ${PANEL_DOMAIN} && ${PANEL_DOMAIN} != "${PUBLIC_HOST}" ]]; then
            san="DNS:${PANEL_DOMAIN},${san}"
        fi
        if ! openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
            -keyout "${key}" -out "${crt}" \
            -subj "/CN=${PANEL_DOMAIN:-${PUBLIC_HOST:-xui-panel}}" \
            -addext "subjectAltName=${san}" >>"${LOG_FILE}" 2>&1; then
            warn "OpenSSL 不支援 -addext，改用基本憑證（瀏覽器可能提示名稱不符）。"
            openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
                -keyout "${key}" -out "${crt}" \
                -subj "/CN=${PANEL_DOMAIN:-${PUBLIC_HOST:-xui-panel}}" >>"${LOG_FILE}" 2>&1 ||
                die "產生自簽憑證失敗。"
        fi
        chmod 600 "${key}"
        chmod 644 "${crt}"
        ok "已產生 10 年期自簽憑證"
    fi

    "${XUI_BIN}" cert -webCert "${crt}" -webCertKey "${key}" >>"${LOG_FILE}" 2>&1 ||
        die "套用面板憑證失敗（x-ui cert）。"
    ok "面板已啟用 HTTPS"
}

panel_scheme() {
    if ((PANEL_TLS == 1)); then printf 'https'; else printf 'http'; fi
}

panel_api_base() {
    printf '%s://127.0.0.1:%s/%s' "$(panel_scheme)" "${PANEL_PORT}" "${PANEL_PATH#/}"
}

restart_panel() {
    info "重啟面板 …"
    systemctl restart "${XUI_SERVICE}" >>"${LOG_FILE}" 2>&1 ||
        die "面板重啟失敗，請查看 journalctl -u x-ui。"
    PANEL_API=$(panel_api_base)
    if ! wait_http "${PANEL_API}/" 40; then
        systemctl status "${XUI_SERVICE}" --no-pager -l 2>&1 | tail -n 20 >&2 || true
        die "面板 40 秒內未回應（${PANEL_API}/）。可能是端口被佔用或憑證錯誤。"
    fi
    ok "面板已就緒：${PANEL_API}/"
}

# ---------------------------------------------------------------------------
# 面板：API 認證
# ---------------------------------------------------------------------------
panel_login() {
    local code
    COOKIE_JAR="${WORKDIR}/cookies.txt"
    : >"${COOKIE_JAR}"

    # 3x-ui v3 的 POST 有 CSRF 保護：先取得 token，再帶 X-CSRF-Token 登入。
    # 舊版沒有 /csrf-token，會返回 404，這一步會靜默跳過。
    CSRF_TOKEN=$(curl -k -sS --max-time 10 -c "${COOKIE_JAR}" -b "${COOKIE_JAR}" \
        "${PANEL_API}/csrf-token" 2>/dev/null |
        jq -r '.obj // empty' 2>/dev/null || true)

    local -a args=(-k -s -o "${WORKDIR}/login.out" -w '%{http_code}'
        -c "${COOKIE_JAR}" -b "${COOKIE_JAR}" --max-time 20
        -X POST "${PANEL_API}/login"
        --data-urlencode "username=${PANEL_USER}"
        --data-urlencode "password=${PANEL_PASS}")
    if [[ -n ${CSRF_TOKEN} ]]; then
        args+=(-H "X-CSRF-Token: ${CSRF_TOKEN}")
    fi

    code=$(curl "${args[@]}" 2>/dev/null) || code="000"
    if [[ ${code} == "200" ]] && jq -e '.success == true' >/dev/null 2>&1 <"${WORKDIR}/login.out"; then
        return 0
    fi
    # 舊版可能只依賴 cookie，沒有 JSON 回應
    if [[ ${code} == "200" ]] && awk -F'\t' 'NF >= 7 && $6 != "" { found = 1 } END { exit !found }' \
        "${COOKIE_JAR}" 2>/dev/null; then
        return 0
    fi
    dbg "login http ${code}: $(head -c 200 "${WORKDIR}/login.out" 2>/dev/null || true)"
    return 1
}

api_authorize() {
    local resp
    API_TOKEN=""

    if [[ -x ${XUI_BIN} ]]; then
        API_TOKEN=$("${XUI_BIN}" setting -getApiToken 2>/dev/null |
            sed -n 's/.*apiToken:[[:space:]]*//p' | tr -d '[:space:]' || true)
    fi

    if [[ -n ${API_TOKEN} ]]; then
        resp=$(curl -k -sS --max-time 15 \
            -H "Authorization: Bearer ${API_TOKEN}" \
            "${PANEL_API}/panel/api/inbounds/list" 2>/dev/null) || resp=""
        if jq -e '.success == true' >/dev/null 2>&1 <<<"${resp}"; then
            ok "面板 API 認證成功（API Token）"
            return 0
        fi
        dbg "token auth failed: ${resp:0:160}"
        API_TOKEN=""
    fi

    if [[ -n ${PANEL_USER} && -n ${PANEL_PASS} ]] && panel_login; then
        ok "面板 API 認證成功（帳號登入）"
        return 0
    fi

    if [[ -t 0 ]]; then
        warn "自動認證失敗。如果你的面板已存在，請輸入管理員帳號密碼（只會用於新增節點）。"
        read -r -p "  面板帳號: " PANEL_USER || true
        read -r -s -p "  面板密碼: " PANEL_PASS || true
        printf '\n'
        if [[ -n ${PANEL_USER} && -n ${PANEL_PASS} ]] && panel_login; then
            ok "面板 API 認證成功"
            return 0
        fi
    fi

    return 1
}

api_curl() {
    local method="$1" path="$2" data="${3:-}"
    local -a args=(-k -sS --max-time 25 -X "${method}")
    if [[ -n ${API_TOKEN} ]]; then
        args+=(-H "Authorization: Bearer ${API_TOKEN}")
    elif [[ -n ${COOKIE_JAR} && -s ${COOKIE_JAR} ]]; then
        args+=(-b "${COOKIE_JAR}")
        [[ -n ${CSRF_TOKEN} ]] && args+=(-H "X-CSRF-Token: ${CSRF_TOKEN}")
    fi
    if [[ -n ${data} ]]; then
        args+=(-H 'Content-Type: application/json' -d "${data}")
    fi
    curl "${args[@]}" "${PANEL_API}${path}"
}

# ---------------------------------------------------------------------------
# 節點：VLESS + Reality
# ---------------------------------------------------------------------------
xray_binary() {
    local bin
    bin=$(find "${XUI_MAIN}/bin" -maxdepth 1 -type f -name 'xray-linux-*' 2>/dev/null | sort | sed -n '1p' || true)
    [[ -n ${bin} ]] || return 1
    printf '%s' "${bin}"
}

generate_reality_keys() {
    local bin out
    bin=$(xray_binary) || die "找不到 Xray 執行檔，面板可能未完整安裝。"
    out=$("${bin}" x25519 2>/dev/null) || die "執行 xray x25519 失敗（Xray 版本可能太舊）。"
    REALITY_PRIV=$(awk -F': *' 'tolower($1) ~ /private/ { print $2; exit }' <<<"${out}")
    REALITY_PUB=$(awk -F': *' 'tolower($1) ~ /(public|password)/ { print $2; exit }' <<<"${out}")
    [[ -n ${REALITY_PRIV} && -n ${REALITY_PUB} ]] ||
        die "解析 Reality 金鑰失敗（Xray 輸出格式有變）。"
    REALITY_SID=$(rand_hex 8)
    REALITY_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)
    [[ -n ${REALITY_UUID} ]] || REALITY_UUID=$(openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')
    REALITY_SUBID=$(rand_hex 8)
}

choose_reality_port() {
    if ! port_in_use "${REALITY_PORT}"; then
        return 0
    fi
    local owner
    owner=$(port_owner "${REALITY_PORT}" || true)
    warn "端口 ${REALITY_PORT} 已被佔用（${owner:-未知程序}），自動改用高位端口避免衝突。"
    local i p
    for ((i = 0; i < 60; i++)); do
        p=$(((RANDOM % 20000) + 20000))
        if ! port_in_use "${p}"; then
            REALITY_PORT="${p}"
            ok "改用端口 ${REALITY_PORT}"
            if [[ -n ${REALITY_PUBLIC_PORT} ]]; then
                warn "節點對外端口 ${REALITY_PUBLIC_PORT} 原本映射到舊內網端口，請同步更新服務商映射。"
            fi
            return 0
        fi
    done
    die "找不到可用端口，請用 --port 指定。"
}

test_reality_dest() {
    local sni="$1"
    if have openssl; then
        if ! timeout 8 openssl s_client -connect "${sni}:443" -servername "${sni}" \
            -tls1_3 </dev/null >>"${LOG_FILE}" 2>&1; then
            warn "Reality 目標 ${sni}:443 的 TLS 1.3 握手未成功。節點可能仍然可用，但建議更換一個 SNI（例如 www.apple.com）。"
            return 0
        fi
        ok "Reality 目標 ${sni}:443 可達（TLS 1.3）"
    fi
}

build_inbound_payload() {
    local settings stream sniff
    settings=$(jq -nc \
        --arg uuid "${REALITY_UUID}" \
        --arg email "ns-${REALITY_SID}" \
        --arg subid "${REALITY_SUBID}" \
        '{clients:[{id:$uuid,flow:"xtls-rprx-vision",email:$email,limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:"",subId:$subid,reset:0}],decryption:"none",fallbacks:[]}')

    stream=$(jq -nc \
        --arg sni "${REALITY_SNI}" \
        --arg priv "${REALITY_PRIV}" \
        --arg pub "${REALITY_PUB}" \
        --arg sid "${REALITY_SID}" \
        '{network:"tcp",security:"reality",externalProxy:[],realitySettings:{show:false,xver:0,dest:($sni+":443"),serverNames:[$sni],privateKey:$priv,minClientVer:"",maxClientVer:"",maxTimeDiff:0,shortIds:[$sid],settings:{publicKey:$pub,fingerprint:"chrome",serverName:"",spiderX:"/"}},tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}}}')

    sniff=$(jq -nc '{enabled:true,destOverride:["http","tls","quic"],metadataOnly:false,routeOnly:false}')

    jq -nc \
        --argjson port "${REALITY_PORT}" \
        --arg remark "${REALITY_REMARK}" \
        --arg settings "${settings}" \
        --arg stream "${stream}" \
        --arg sniff "${sniff}" \
        '{up:0,down:0,total:0,remark:$remark,enable:true,expiryTime:0,listen:"",port:$port,protocol:"vless",settings:$settings,streamSettings:$stream,sniffing:$sniff,allocate:"{\"strategy\":\"always\",\"refresh\":5,\"concurrency\":3}"}'
}

create_reality_inbound() {
    stage "reality" "建立 VLESS + Reality 節點"

    [[ -n ${REALITY_REMARK} ]] || REALITY_REMARK="HK-Reality-${REALITY_PORT}"

    if ! api_authorize; then
        if ((FRESH_INSTALL == 1)); then
            die "面板 API 認證失敗，無法自動建立節點。請將 ${LOG_FILE} 最後 30 行貼給我們。"
        fi
        warn "無法認證面板 API，跳過自動建立節點。"
        warn "可稍後在面板手動匯入（或用 --force-panel-reset 重設帳號密碼後再次執行）。"
        return 0
    fi

    local existing
    existing=$(api_curl GET "/panel/api/inbounds/list" 2>/dev/null || true)
    if jq -e --arg r "${REALITY_REMARK}" '[.obj[]? | select(.remark == $r)] | length > 0' \
        >/dev/null 2>&1 <<<"${existing}"; then
        ok "節點「${REALITY_REMARK}」已存在，跳過建立"
        return 0
    fi

    choose_reality_port
    REALITY_REMARK="HK-Reality-${REALITY_PORT}"
    generate_reality_keys
    test_reality_dest "${REALITY_SNI}"

    local payload resp msg
    payload=$(build_inbound_payload)
    printf '%s\n' "${payload}" >"${WORKDIR}/inbound.json"

    resp=$(api_curl POST "/panel/api/inbounds/add" "${payload}") ||
        die "呼叫面板 API 失敗（可能是面板版本差異）。"

    if ! jq -e '.success == true' >/dev/null 2>&1 <<<"${resp}"; then
        # 3x-ui 新舊版本對 settings 的類型要求不同：舊版接受 JSON 字串，新版可能接受物件。
        # 先用字串試，失敗就轉成物件再試一次。
        local payload_obj
        payload_obj=$(jq -c '.settings |= fromjson | .streamSettings |= fromjson | .sniffing |= fromjson | .allocate |= fromjson' <<<"${payload}" 2>/dev/null || true)
        if [[ -n ${payload_obj} ]]; then
            resp=$(api_curl POST "/panel/api/inbounds/add" "${payload_obj}") || true
        fi
    fi

    if ! jq -e '.success == true' >/dev/null 2>&1 <<<"${resp}"; then
        msg=$(jq -r '.msg // empty' <<<"${resp}" 2>/dev/null || true)
        err "面板回應：${msg:-${resp:0:300}}"
        cp "${WORKDIR}/inbound.json" "/root/xui-shield-inbound-failed.json" 2>/dev/null || true
        die "面板拒絕新增節點。已將 JSON 存到 /root/xui-shield-inbound-failed.json。"
    fi
    ok "節點已建立（內網 ${REALITY_PORT} → 對外 $(reality_public_port)，SNI ${REALITY_SNI}）"

    systemctl restart "${XUI_SERVICE}" >>"${LOG_FILE}" 2>&1 || true
    if ! wait_port "${REALITY_PORT}" 30; then
        journalctl -u "${XUI_SERVICE}" -n 30 --no-pager >>"${LOG_FILE}" 2>&1 || true
        die "節點端口 ${REALITY_PORT} 未監聽，Xray 可能啟動失敗。"
    fi
    ok "端口 ${REALITY_PORT} 已監聽"
}

write_client_info() {
    local link host rport pport panel_url
    host=$(public_host)
    [[ -n ${host} ]] || host="<你的伺服器IP>"
    rport=$(reality_public_port)
    pport=$(panel_public_port)
    panel_url=$(panel_access_url)

    link=$(printf 'vless://%s@%s:%s?type=tcp&security=reality&pbk=%s&fp=chrome&sni=%s&sid=%s&spx=%%2F&flow=xtls-rprx-vision#%s' \
        "${REALITY_UUID}" "${host}" "${rport}" "${REALITY_PUB}" \
        "${REALITY_SNI}" "${REALITY_SID}" "${REALITY_REMARK}")

    CLIENT_LINK="${link}"

    {
        printf '# xui-shield · 客戶端資訊（請妥善保管，內含面板密碼）\n'
        printf '# 產生時間：%s\n\n' "$(date '+%F %T')"
        printf '面板網址：%s\n' "${panel_url}"
        printf '面板帳號：%s\n' "${PANEL_USER}"
        printf '面板密碼：%s\n\n' "${PANEL_PASS}"
        printf '節點名稱：%s\n' "${REALITY_REMARK}"
        printf '協議：VLESS + Reality（TCP）\n'
        printf '地址：%s\n端口：%s\n' "${host}" "${rport}"
        if [[ ${rport} != "${REALITY_PORT}" ]]; then
            printf '端口映射：對外 %s → 內網 %s（請在 VPS 服務商面板確認）\n' "${rport}" "${REALITY_PORT}"
        fi
        if [[ ${pport} != "${PANEL_PORT}" ]]; then
            printf '面板端口映射：對外 %s → 內網 %s\n' "${pport}" "${PANEL_PORT}"
        fi
        printf 'UUID：%s\nPublicKey：%s\nShortId：%s\nSNI：%s\nFlow：xtls-rprx-vision\n\n' \
            "${REALITY_UUID}" "${REALITY_PUB}" "${REALITY_SID}" "${REALITY_SNI}"
        printf '分享連結：\n%s\n' "${link}"
    } >"${CLIENT_LINK_FILE}"
    chmod 600 "${CLIENT_LINK_FILE}"
}

verify_xray_config() {
    local bin cfg
    bin=$(xray_binary) || return 0
    cfg="${XUI_MAIN}/bin/config.json"
    [[ -r ${cfg} ]] || return 0
    if ! "${bin}" -test -config "${cfg}" >>"${LOG_FILE}" 2>&1; then
        die "Xray 設定檢查失敗（xray -test）。詳見 ${LOG_FILE}。"
    fi
    ok "Xray 設定檢查通過"
}

# ---------------------------------------------------------------------------
# 防火牆
# ---------------------------------------------------------------------------
ufw_rule_exists() {
    # $1=port/proto  $2=ALLOW|LIMIT
    local spec="$1" action="$2"
    ufw status 2>/dev/null | grep -qE "^${spec}[[:space:]]+${action}" && return 0
    ufw show added 2>/dev/null | grep -qE "^ufw ${action,,} ${spec}([[:space:]]|$)" && return 0
    return 1
}

ufw_allow() {
    local spec="$1" comment="${2:-xui-shield}"
    ufw_rule_exists "${spec}" "ALLOW" && return 0
    ufw allow "${spec}" comment "${comment}" >/dev/null 2>&1 ||
        ufw allow "${spec}" >/dev/null 2>&1 || return 1
}

ufw_limit() {
    local spec="$1" comment="${2:-xui-shield}"
    ufw_rule_exists "${spec}" "LIMIT" && return 0
    ufw limit "${spec}" comment "${comment}" >/dev/null 2>&1 ||
        ufw limit "${spec}" >/dev/null 2>&1 || return 1
}

fw_guard_install() {
    cat >"${FW_GUARD_BIN}" <<'EOS'
#!/usr/bin/env bash
# 由 xui-shield 自動產生：如果 15 分鐘內管理員未確認 SSH 仍然正常，
# 就關閉 UFW，避免把自己鎖在門外。
set -u
MARK="/run/xui-shield-fw-ok"
LOG="/var/log/xui-shield.log"
if [[ -e "${MARK}" ]]; then
    exit 0
fi
# 如果 UFW 本來就是啟用狀態，不要擅自關閉用戶原有的防火牆
if [[ -e "/var/lib/xui-shield/fw-was-active" ]]; then
    logger -t xui-shield "firewall not confirmed; UFW was already active before xui-shield, leaving it as-is" 2>/dev/null || true
    exit 0
fi
logger -t xui-shield "firewall not confirmed in 15 minutes; disabling ufw to avoid SSH lockout" 2>/dev/null || true
ufw --force disable >>"${LOG}" 2>&1 || true
printf '%s [xui-shield] UFW 已自動關閉（15 分鐘內未確認 SSH）\n' "$(date '+%F %T')" >>"${LOG}" 2>/dev/null || true
EOS
    chmod 755 "${FW_GUARD_BIN}"
}

arm_fw_rollback() {
    rm -f "${FW_CONFIRM_MARK}"
    fw_guard_install

    # 清除上次未確認的殘留 timer
    systemctl stop xui-shield-fw-guard.timer >/dev/null 2>&1 || true
    systemctl stop xui-shield-fw-guard.service >/dev/null 2>&1 || true
    systemctl reset-failed xui-shield-fw-guard.service >/dev/null 2>&1 || true

    if have systemd-run; then
        if systemd-run --quiet --collect --unit=xui-shield-fw-guard \
            --on-active=15min --timer-property=AccuracySec=10s \
            "${FW_GUARD_BIN}" >/dev/null 2>&1; then
            ok "已啟動 15 分鐘自動回滾保護（確認 SSH 正常後會取消）"
            return 0
        fi
    fi
    if have at; then
        if printf '%s\n' "${FW_GUARD_BIN}" | at now + 15 minutes >/dev/null 2>&1; then
            ok "已啟動 15 分鐘自動回滾保護（at）"
            return 0
        fi
    fi
    warn "無法建立自動回滾計時器！請確保你的 SSH 端口 ${SSH_PORTS} 已放行。"
}

confirm_firewall() {
    touch "${FW_CONFIRM_MARK}"
    if have systemctl; then
        systemctl stop xui-shield-fw-guard.timer >/dev/null 2>&1 || true
        systemctl stop xui-shield-fw-guard.service >/dev/null 2>&1 || true
        systemctl reset-failed xui-shield-fw-guard.service >/dev/null 2>&1 || true
    fi
    ok "防火牆已確認保留，自動回滾已取消"
}

fw_apply_ufw() {
    install -d -m 700 "${STATE_DIR}"
    info "備份現有 UFW 規則 …"
    ufw status numbered >"${STATE_DIR}/ufw-before.txt" 2>&1 || true

    local was_active=0
    if ufw status 2>/dev/null | grep -q 'Status: active'; then
        was_active=1
        warn "偵測到 UFW 之前已經啟用：我只會新增規則，不會 reset 你原有設定。"
    fi

    ufw --force default deny incoming >>"${LOG_FILE}" 2>&1 ||
        die "設定 UFW 預設拒絕傳入失敗。"
    ufw --force default allow outgoing >>"${LOG_FILE}" 2>&1 || true
    ufw --force logging low >>"${LOG_FILE}" 2>&1 || true

    if [[ -f /etc/default/ufw ]]; then
        if grep -q '^IPV6=' /etc/default/ufw; then
            sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
        else
            printf 'IPV6=yes\n' >>/etc/default/ufw
        fi
    fi

    local p
    for p in ${SSH_PORTS//,/ }; do
        ufw_limit "${p}/tcp" "SSH ${p} (rate-limited)" ||
            die "無法為 SSH 端口 ${p} 加入放行規則，已中止（防止鎖死 SSH）。"
        ok "SSH ${p}/tcp 已放行（限速 6 次/30 秒）"
    done

    if ((PANEL_LOCAL == 0)) && [[ -n ${PANEL_PORT} ]]; then
        ufw_allow "${PANEL_PORT}/tcp" "3x-ui panel" ||
            warn "面板端口 ${PANEL_PORT} 放行失敗，稍後請手動處理。"
        ok "面板 ${PANEL_PORT}/tcp 已放行"
    elif ((PANEL_LOCAL == 1)); then
        ok "面板綁定 127.0.0.1，無需對外放行"
    fi

    ufw_allow "${REALITY_PORT}/tcp" "VLESS Reality" ||
        die "無法放行節點端口 ${REALITY_PORT}/tcp。"
    ok "節點 ${REALITY_PORT}/tcp 已放行"

    # 不要弄壞用戶原有網站：如果 80/443 有其它服務，保留放行
    if port_in_use 80; then
        ufw_allow "80/tcp" "existing http" && warn "偵測到現有 HTTP 服務，已一併保留 80/tcp"
    fi
    if ((REALITY_PORT != 443)) && port_in_use 443; then
        ufw_allow "443/tcp" "existing https" && warn "偵測到現有 HTTPS 服務，已一併保留 443/tcp"
    fi

    # 開啟前最後檢查：SSH 規則必須存在
    for p in ${SSH_PORTS//,/ }; do
        ufw_rule_exists "${p}/tcp" "LIMIT" ||
            die "SSH 端口 ${p} 的規則不見了，為安全起見不會啟用防火牆。"
    done

    if ((was_active == 1)); then
        : >"${STATE_DIR}/fw-was-active"
    else
        rm -f "${STATE_DIR}/fw-was-active"
    fi

    arm_fw_rollback

    ufw --force enable >>"${LOG_FILE}" 2>&1 ||
        die "UFW 啟用失敗。"
    ufw status | grep -q 'Status: active' || die "UFW 未進入 active 狀態。"

    # 保護萬一 enable 之後規則次序有變
    for p in ${SSH_PORTS//,/ }; do
        ufw_rule_exists "${p}/tcp" "LIMIT" || {
            ufw --force disable >>"${LOG_FILE}" 2>&1 || true
            die "啟用後 SSH 規則消失，已緊急關閉防火牆。"
        }
    done
    ok "UFW 已啟用（預設拒絕傳入，只放行必要端口）"
}

fw_apply_firewalld() {
    info "備份現有 firewalld 規則 …"
    firewall-cmd --list-all >"${STATE_DIR}/firewalld-before.txt" 2>&1 || true

    local zone
    zone=$(firewall-cmd --get-default-zone 2>/dev/null || echo public)
    if [[ ${zone} == "trusted" || ${zone} == "block" ]]; then
        warn "預設 zone 是 ${zone}，行為可能與預期不同，請自行確認。"
    fi

    firewall-cmd --permanent --add-service=ssh >>"${LOG_FILE}" 2>&1 || true

    local p
    for p in ${SSH_PORTS//,/ }; do
        firewall-cmd --permanent --add-port="${p}/tcp" >>"${LOG_FILE}" 2>&1 || true
    done
    if ((PANEL_LOCAL == 0)) && [[ -n ${PANEL_PORT} ]]; then
        firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp" >>"${LOG_FILE}" 2>&1 || true
    fi
    firewall-cmd --permanent --add-port="${REALITY_PORT}/tcp" >>"${LOG_FILE}" 2>&1 || true

    systemctl enable --now firewalld >>"${LOG_FILE}" 2>&1 ||
        die "firewalld 啟動失敗。"
    firewall-cmd --reload >>"${LOG_FILE}" 2>&1 || die "firewalld reload 失敗。"

    firewall-cmd --query-port="${REALITY_PORT}/tcp" >/dev/null 2>&1 ||
        die "firewalld 未成功放行節點端口 ${REALITY_PORT}。"
    ok "firewalld 已放行 SSH（${SSH_PORTS}）、面板 ${PANEL_PORT}、節點 ${REALITY_PORT}"
}

stage_firewall() {
    ((FIREWALL_ENABLE == 1)) || {
        warn "已停用防火牆設定（--no-firewall）"
        return 0
    }
    stage "firewall" "自動化防火牆防禦"

    if have docker && systemctl is-active --quiet docker 2>/dev/null; then
        warn "偵測到 Docker：容器 publish 出來的端口會繞過 UFW。"
        warn "如有容器要對外，請將端口綁定到 127.0.0.1，或自行加入 DOCKER-USER 規則。"
    fi

    if [[ -z ${FW_BACKEND} ]]; then
        if have firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
            FW_BACKEND="firewalld"
        elif have ufw; then
            FW_BACKEND="ufw"
        elif have firewall-cmd; then
            FW_BACKEND="firewalld"
        else
            FW_BACKEND="ufw"
        fi
    fi

    case "${FW_BACKEND}" in
        ufw)
            have ufw || die "UFW 未安裝。"
            fw_apply_ufw
            ;;
        firewalld)
            have firewall-cmd || die "firewalld 未安裝。"
            fw_apply_firewalld
            ;;
        *)
            die "未知防火牆後端：${FW_BACKEND}"
            ;;
    esac
}

prompt_firewall_confirm() {
    ((FIREWALL_ENABLE == 1)) || return 0
    [[ ${FW_BACKEND} == "ufw" ]] || return 0

    printf '\n'
    warn "防火牆已開啟。請「保持目前 SSH 連線」，另開一個視窗測試新連線。"
    if ((ASSUME_YES == 1)); then
        warn "--yes：自動確認保留防火牆。請自行確認 SSH 仍然可以連線。"
        confirm_firewall
        return 0
    fi
    if [[ -t 0 ]]; then
        local rc=0
        read -r -t 120 -p "  SSH 仍然正常？按 Enter 確認保留（120 秒後自動回滾）: " _ || rc=$?
        if ((rc == 0)); then
            confirm_firewall
        else
            warn "未收到確認。15 分鐘後會自動關閉 UFW；如連線正常，執行：${SELF_CMD} --confirm-firewall"
        fi
    else
        warn "非互動模式：15 分鐘後自動關閉 UFW。連線正常請執行：${SELF_CMD} --confirm-firewall"
    fi
}

# ---------------------------------------------------------------------------
# Fail2ban
# ---------------------------------------------------------------------------
setup_fail2ban() {
    ((FAIL2BAN_ENABLE == 1)) || {
        warn "已停用 Fail2ban（--no-fail2ban）"
        return 0
    }
    stage "fail2ban" "SSH 暴力破解防禦（Fail2ban）"

    have fail2ban-client || {
        warn "Fail2ban 未安裝，跳過。"
        return 0
    }

    install -d -m 755 /etc/fail2ban/jail.d
    cat >"${F2B_JAIL_FILE}" <<EOF
# 由 xui-shield 產生（${BRAND_SITE}）
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
maxretry = 4
bantime  = 24h
findtime = 10m
EOF

    if ! fail2ban-client -t >>"${LOG_FILE}" 2>&1; then
        rm -f "${F2B_JAIL_FILE}"
        warn "Fail2ban 設定檢查失敗，已移除自訂 jail（原有設定不受影響）。"
        return 0
    fi

    systemctl enable fail2ban >>"${LOG_FILE}" 2>&1 || true
    systemctl restart fail2ban >>"${LOG_FILE}" 2>&1 || true

    local i=0
    while ((i < 10)); do
        systemctl is-active --quiet fail2ban && break
        sleep 1
        i=$((i + 1))
    done

    if ! systemctl is-active --quiet fail2ban; then
        journalctl -u fail2ban -n 20 --no-pager >>"${LOG_FILE}" 2>&1 || true
        die "Fail2ban 啟動失敗。"
    fi
    if ! fail2ban-client status sshd 2>/dev/null | grep -q 'Status for the jail'; then
        warn "sshd jail 未生效，請檢查 fail2ban 設定。"
    else
        ok "sshd jail 已生效（4 次失敗 → 封鎖 24 小時）"
    fi
}

# ---------------------------------------------------------------------------
# 內核參數 / BBR
# ---------------------------------------------------------------------------
apply_sysctl() {
    ((BBR_ENABLE == 1)) || {
        warn "已停用內核參數調整（--no-bbr）"
        return 0
    }
    stage "sysctl" "內核參數與 BBR 加速"

    cat >"${SYSCTL_FILE}" <<'EOF'
# 由 xui-shield 產生：代理場景常用的 TCP / 防護參數
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_notsent_lowat = 16384
# NAT 映射容易因空閒而過期：用較短的 keepalive 保持連線
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.core.somaxconn = 4096
net.ipv4.ip_local_port_range = 10240 65000
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
EOF

    local bbr_ok=0
    modprobe tcp_bbr >>"${LOG_FILE}" 2>&1 || true
    if grep -qw 'bbr' /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' >>"${SYSCTL_FILE}"
        bbr_ok=1
    fi

    if sysctl --system >>"${LOG_FILE}" 2>&1; then
        ok "內核參數已套用"
    else
        warn "部分內核參數不支援（容器環境常見），已忽略失敗項。"
    fi

    if ((bbr_ok == 1)) &&
        [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == "bbr" ]]; then
        ok "BBR 已啟用（擁塞控制：bbr，隊列：fq）"
    else
        warn "BBR 未啟用（OpenVZ / LXC 或舊內核常見）。會沿用系統預設擁塞控制。"
    fi
}

# ---------------------------------------------------------------------------
# x-ui 檔案描述符上限
# ---------------------------------------------------------------------------
apply_xui_limits() {
    install -d -m 755 /etc/systemd/system/x-ui.service.d
    cat >/etc/systemd/system/x-ui.service.d/20-xui-shield-limits.conf <<'EOF'
# 由 xui-shield 產生：提高並發連線上限
[Service]
LimitNOFILE=1048576
EOF
    systemctl daemon-reload >>"${LOG_FILE}" 2>&1 || true
    ok "x-ui 檔案描述符上限：1048576"
}

# ---------------------------------------------------------------------------
# 每日備份
# ---------------------------------------------------------------------------
install_backup_helper() {
    cat >"${BACKUP_HELPER}" <<'BACKUP_EOF'
#!/usr/bin/env bash
# 由 xui-shield 產生：3x-ui 每日備份
# 還原：bash xui-shield.sh --restore <這個 .tar.gz>
set -Eeuo pipefail

CONF="/etc/xui-shield/config.env"
if [[ -r "${CONF}" ]]; then
    # shellcheck disable=SC1090
    . "${CONF}"
fi

BACKUP_DIR="${BACKUP_DIR:-/var/backups/x-ui}"
KEEP="${BACKUP_KEEP:-14}"
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
LOG="/var/log/xui-shield-backup.log"
DB="/etc/x-ui/x-ui.db"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"${LOG}" 2>/dev/null || true; }
fail() { log "ERR  $*"; printf '備份失敗：%s\n' "$*" >&2; exit 1; }

command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 未安裝"
[[ -r "${DB}" ]] || fail "找不到資料庫 ${DB}"

install -d -m 700 "${BACKUP_DIR}" || fail "無法建立備份目錄 ${BACKUP_DIR}"

ts=$(date +%Y%m%d-%H%M%S)
work=$(mktemp -d) || fail "無法建立暫存目錄"
trap 'rm -rf "${work}"' EXIT

mkdir -p "${work}/meta"

# 1) SQLite 一致性快照（不會鎖住面板）
sqlite3 "${DB}" ".backup '${work}/x-ui.db'" || fail "SQLite 備份失敗"

# 2) /etc/x-ui（憑證、設定；資料庫由上面的一致性快照負責）
if [[ -d /etc/x-ui ]]; then
    mkdir -p "${work}/etc-x-ui"
    cp -a /etc/x-ui/. "${work}/etc-x-ui/" 2>/dev/null || true
    find "${work}/etc-x-ui" -maxdepth 1 -name 'x-ui.db*' -delete 2>/dev/null || true
fi

# 3) 憑證目錄（用絕對路徑打包，還原時直接解到 /）
if [[ -d /root/cert ]]; then
    tar -czf "${work}/certs-root.tar.gz" -C / root/cert 2>/dev/null || true
fi
if [[ -d /usr/local/x-ui/cert ]]; then
    tar -czf "${work}/certs-xui.tar.gz" -C / usr/local/x-ui/cert 2>/dev/null || true
fi

# 4) 診斷資料，方便日後查問題
{
    printf '時間：%s\n' "$(date '+%F %T')"
    printf '主機：%s\n' "$(hostname 2>/dev/null || echo unknown)"
    printf '系統：%s\n' "$(head -n1 /etc/os-release 2>/dev/null || echo unknown)"
    printf '面板：%s\n' "$(/usr/local/x-ui/x-ui -v 2>/dev/null || echo unknown)"
} >"${work}/meta/info.txt" 2>/dev/null

ss -ltnp >"${work}/meta/listen.txt" 2>/dev/null || true
ufw status verbose >"${work}/meta/ufw.txt" 2>/dev/null || true
firewall-cmd --list-all >"${work}/meta/firewalld.txt" 2>/dev/null || true
fail2ban-client status >"${work}/meta/fail2ban.txt" 2>/dev/null || true
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc \
    >"${work}/meta/sysctl.txt" 2>/dev/null || true
/usr/local/x-ui/x-ui setting -show true >"${work}/meta/panel-settings.txt" 2>/dev/null || true
cp -f "${CONF}" "${work}/meta/xui-shield-config.env" 2>/dev/null || true

# 5) 校驗 + 打包
(
    cd "${work}" || exit 1
    find . -type f ! -name SHA256SUMS -print0 |
        sort -z |
        xargs -0 sha256sum >SHA256SUMS 2>/dev/null || true
)

out="${BACKUP_DIR}/xui-shield-backup-${ts}.tar.gz"
tar -czf "${out}" -C "${work}" . || fail "打包失敗"
chmod 600 "${out}"
tar -tzf "${out}" >/dev/null 2>&1 || fail "備份檔完整性檢查失敗"

# 6) 清理舊備份
find "${BACKUP_DIR}" -maxdepth 1 -type f -name 'xui-shield-backup-*.tar.gz' \
    -mtime +"${KEEP}" -print0 2>/dev/null | xargs -0 -r rm -f -- 2>/dev/null || true

log "OK   ${out} ($(du -h "${out}" | awk '{print $1}'))"

# 7) 可選：上傳 Telegram
if [[ -n "${TG_BOT_TOKEN}" && -n "${TG_CHAT_ID}" ]] && command -v curl >/dev/null 2>&1; then
    if curl -fsS --max-time 120 \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
        -F "chat_id=${TG_CHAT_ID}" \
        -F "caption=3x-ui 備份 $(hostname 2>/dev/null) ${ts}" \
        -F "document=@${out}" >/dev/null 2>&1; then
        log "OK   Telegram 上傳成功"
    else
        log "WARN Telegram 上傳失敗（備份檔案仍然有效）"
    fi
fi

printf '%s\n' "${out}"
BACKUP_EOF
    chmod 755 "${BACKUP_HELPER}"
    ok "備份工具：${BACKUP_HELPER}"
}

install_backup_timer() {
    ((BACKUP_ENABLE == 1)) || {
        warn "已停用每日備份（--no-backup）"
        return 0
    }
    stage "backup" "每日自動備份"

    if ! [[ ${BACKUP_TIME} =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        die "備份時間格式錯誤：${BACKUP_TIME}（要 HH:MM，例如 04:30）"
    fi
    if ! [[ ${BACKUP_KEEP} =~ ^[0-9]+$ ]] || ((BACKUP_KEEP < 1)); then
        die "保留天數必須是正整數（目前：${BACKUP_KEEP}）"
    fi

    install -d -m 700 "${BACKUP_DIR}"
    install_backup_helper

    cat >/etc/systemd/system/xui-shield-backup.service <<EOF
[Unit]
Description=3x-ui daily backup (xui-shield)
After=x-ui.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${BACKUP_HELPER}
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF

    cat >/etc/systemd/system/xui-shield-backup.timer <<EOF
[Unit]
Description=Daily 3x-ui backup timer (xui-shield)

[Timer]
OnCalendar=*-*-* ${BACKUP_TIME}:00
Persistent=true
RandomizedDelaySec=15m
Unit=xui-shield-backup.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload >>"${LOG_FILE}" 2>&1 || true
    systemctl enable --now xui-shield-backup.timer >>"${LOG_FILE}" 2>&1 ||
        die "備份定時器啟用失敗。"

    info "先執行一次備份驗證 …"
    if ! systemctl start xui-shield-backup.service >>"${LOG_FILE}" 2>&1; then
        journalctl -u xui-shield-backup.service -n 30 --no-pager >>"${LOG_FILE}" 2>&1 || true
        die "首次備份失敗，請查看 ${LOG_FILE} 及 journalctl -u xui-shield-backup。"
    fi

    local latest
    latest=$(find "${BACKUP_DIR}" -maxdepth 1 -type f -name 'xui-shield-backup-*.tar.gz' \
        -mmin -15 -print 2>/dev/null | sort | tail -n1 || true)
    if [[ -z ${latest} ]]; then
        die "備份指令完成但找不到新檔案，請檢查 ${BACKUP_DIR}。"
    fi
    ok "首次備份完成：${latest}（$(du -h "${latest}" | awk '{print $1}')）"
    ok "每日 ${BACKUP_TIME} 自動備份，保留 ${BACKUP_KEEP} 天"
}

# ---------------------------------------------------------------------------
# 驗證 / 報告
# ---------------------------------------------------------------------------
check_nat_reachability() {
    nat_mode || return 0

    local host rport pport
    host=$(public_host)
    rport=$(reality_public_port)
    pport=$(panel_public_port)

    info "NAT 連通性自檢：${host}:${rport}"

    if [[ ! ${host} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && ! getent hosts "${host}" >/dev/null 2>&1; then
        warn "域名 ${host} 無法解析，DDNS 可能尚未生效。"
        return 0
    fi

    if timeout 6 bash -c "exec 3<>/dev/tcp/${host}/${rport}" 2>/dev/null; then
        ok "對外 ${host}:${rport} 可連接"
    else
        warn "無法從本機連到 ${host}:${rport}。"
        warn "可能原因：NAT 不支援 hairpin、服務商映射未生效、DDNS 未更新，或防火牆未放行內網端口。"
        warn "若從外部網絡可以連接，代表只是本機不支援 hairpin，屬正常現象。"
        warn "請用外部網絡測試：nc -vz ${host} ${rport}"
    fi

    if timeout 6 bash -c "exec 3<>/dev/tcp/${host}/${pport}" 2>/dev/null; then
        ok "面板對外 ${host}:${pport} 可連接"
    else
        warn "面板對外 ${host}:${pport} 無法從本機連接（可能同樣是 hairpin 限制）。"
    fi
}

verify_all() {
    stage "verify" "自我檢查"

    local failed=0
    verify_xray_config

    if systemctl is-active --quiet "${XUI_SERVICE}"; then
        ok "面板服務運行中"
    else
        err "面板服務未運行"
        failed=1
    fi

    if port_in_use "${PANEL_PORT}"; then
        ok "面板端口 ${PANEL_PORT} 監聽中"
    else
        err "面板端口 ${PANEL_PORT} 未監聽"
        failed=1
    fi

    if [[ -n ${REALITY_UUID} ]]; then
        if port_in_use "${REALITY_PORT}"; then
            ok "節點端口 ${REALITY_PORT} 監聽中"
        else
            err "節點端口 ${REALITY_PORT} 未監聽"
            failed=1
        fi
    fi

    if ((FIREWALL_ENABLE == 1)); then
        if [[ ${FW_BACKEND} == "ufw" ]]; then
            if ufw status 2>/dev/null | grep -q 'Status: active'; then
                ok "UFW 已啟用"
            else
                err "UFW 未啟用"
                failed=1
            fi
        elif [[ ${FW_BACKEND} == "firewalld" ]]; then
            if systemctl is-active --quiet firewalld; then
                ok "firewalld 已啟用"
            else
                err "firewalld 未啟用"
                failed=1
            fi
        fi
    fi

    if ((FAIL2BAN_ENABLE == 1)); then
        if systemctl is-active --quiet fail2ban; then
            ok "Fail2ban 運行中"
        else
            warn "Fail2ban 未運行"
        fi
    fi

    if ((BACKUP_ENABLE == 1)); then
        if systemctl is-active --quiet xui-shield-backup.timer; then
            ok "每日備份定時器已啟用"
        else
            warn "備份定時器未啟用"
        fi
    fi

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == "bbr" ]]; then
        ok "BBR 已啟用"
    fi

    if nat_mode; then
        warn "NAT 模式：請確認服務商已將對外 $(reality_public_port) 映射到內網 ${REALITY_PORT}，對外 $(panel_public_port) 映射到內網 ${PANEL_PORT}。"
        check_nat_reachability
    elif ((NAT_SUSPECT == 1)); then
        warn "偵測到疑似 NAT 網絡；若端口有映射，請用 --public-port / --panel-public-port 指定。"
    fi

    if ((failed == 1)); then
        die "自我檢查未通過，請將上面的訊息和 ${LOG_FILE} 貼給我們。"
    fi
}

panel_access_url() {
    local host scheme
    scheme=$(panel_scheme)
    if ((PANEL_LOCAL == 1)); then
        printf '%s://127.0.0.1:%s/%s/' "${scheme}" "${PANEL_PORT}" "${PANEL_PATH#/}"
        return
    fi
    host=$(panel_host)
    printf '%s://%s:%s/%s/' "${scheme}" "${host}" "$(panel_public_port)" "${PANEL_PATH#/}"
}

print_report() {
    local url
    url=$(panel_access_url)

    printf '\n'
    hr "═" 70
    printf '  %s%s部署摘要%s\n' "${C_BOLD}" "${C_WHITE}" "${C_RESET}"
    hr "═" 70

    printf '  %s面板%s      %s%s%s\n' "${C_BOLD}" "${C_RESET}" "${C_NEON}" "${url}" "${C_RESET}"
    if ((PANEL_LOCAL == 1)); then
        printf '  %s隧道%s      ssh -L 8080:127.0.0.1:%s root@%s\n' \
            "${C_BOLD}" "${C_RESET}" "${PANEL_PORT}" "${PUBLIC_IP}"
    fi
    printf '  %s帳號%s      %s\n' "${C_BOLD}" "${C_RESET}" "${PANEL_USER:-（沿用原有帳號）}"
    [[ -n ${PANEL_PASS} ]] && printf '  %s密碼%s      %s\n' "${C_BOLD}" "${C_RESET}" "${PANEL_PASS}"

    if [[ -n ${REALITY_UUID} ]]; then
        printf '\n  %s節點%s      %s（VLESS + Reality）\n' "${C_BOLD}" "${C_RESET}" "${REALITY_REMARK}"
        printf '  %s端口%s      %s/tcp　SNI: %s\n' "${C_BOLD}" "${C_RESET}" "$(reality_public_port)" "${REALITY_SNI}"
        if [[ $(reality_public_port) != "${REALITY_PORT}" ]]; then
            printf '  %s映射%s      對外 %s → 內網 %s（請在服務商面板確認）\n' \
                "${C_BOLD}" "${C_RESET}" "$(reality_public_port)" "${REALITY_PORT}"
        fi
        printf '  %s連結%s      %s\n' "${C_BOLD}" "${C_RESET}" "${CLIENT_LINK:-（見 ${CLIENT_LINK_FILE}）}"
    else
        printf '\n  %s節點%s      %s未自動建立（請在面板手動新增，或用 --force-panel-reset 重新執行）%s\n' \
            "${C_BOLD}" "${C_RESET}" "${C_YELLOW}" "${C_RESET}"
    fi

    if ((FIREWALL_ENABLE == 1)); then
        printf '  %s防火牆%s    %s · SSH %s · 面板 %s · 節點 %s\n' "${C_BOLD}" "${C_RESET}" \
            "$([[ ${FW_BACKEND} == firewalld ]] && echo 'firewalld' || echo 'UFW')" \
            "${SSH_PORTS}" "${PANEL_PORT}" "${REALITY_PORT}"
    else
        printf '  %s防火牆%s    已停用（--no-firewall）\n' "${C_BOLD}" "${C_RESET}"
    fi
    if nat_mode; then
        printf '  %sNAT%s       對外 %s → 內網 %s　面板 %s → 內網 %s\n' "${C_BOLD}" "${C_RESET}" \
            "$(reality_public_port)" "${REALITY_PORT}" "$(panel_public_port)" "${PANEL_PORT}"
    fi
    printf '  %s備份%s      %s\n' "${C_BOLD}" "${C_RESET}" \
        "$([[ ${BACKUP_ENABLE} -eq 1 ]] && echo "每日 ${BACKUP_TIME} · 保留 ${BACKUP_KEEP} 天 · ${BACKUP_DIR}" || echo '已停用')"
    printf '  %s憑證%s      %s（如為自簽，瀏覽器首次會提示）\n' "${C_BOLD}" "${C_RESET}" \
        "$([[ ${PANEL_TLS} -eq 1 ]] && panel_host || echo '未啟用 HTTPS')"

    printf '\n  %s提示%s\n' "${C_BOLD}${C_GOLD}" "${C_RESET}"
    printf '    · 客戶端資訊（含面板密碼）已存到 %s（權限 600）\n' "${CLIENT_LINK_FILE}"
    if nat_mode; then
        printf '    · NAT / 動態 IP：請在服務商面板確認端口映射，並用 DDNS 域名取代固定 IP\n'
    fi
    if { ((NAT_SUSPECT == 1)) || nat_mode; } &&
        [[ $(public_host) =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        printf '    · %s注意%s：目前連結使用 IP；若 IP 每天更換，請改用 DDNS 域名（--public-host）\n' \
            "${C_BOLD}${C_YELLOW}" "${C_RESET}"
    fi
    printf '    · 想更換真憑證：把 fullchain.pem / privkey.pem 放到 /etc/x-ui/cert/ 後執行 x-ui restart\n'
    printf '    · 想更換 SNI 或端口：重新執行 %s --port 8443 --sni www.apple.com\n' "${SELF_CMD}"
    if ((FIREWALL_ENABLE == 1)) && [[ ${FW_BACKEND} == "ufw" ]]; then
        printf '    · %s重要%s：15 分鐘內確認 SSH 正常，然後執行 %s --confirm-firewall\n' \
            "${C_BOLD}${C_YELLOW}" "${C_RESET}" "${SELF_CMD}"
    fi
    printf '    · 完整日誌：%s\n' "${LOG_FILE}"
    hr "═" 70
}

# ---------------------------------------------------------------------------
# 狀態
# ---------------------------------------------------------------------------
show_status() {
    printf '\n%s%s  XUI-SHIELD 狀態%s\n' "${C_BOLD}" "${C_CYAN}" "${C_RESET}"
    hr "─" 60

    if [[ -x ${XUI_BIN} ]]; then
        printf '  面板版本    %s\n' "$("${XUI_BIN}" -v 2>/dev/null | sed -n '1p' || echo '未知')"
        if systemctl is-active --quiet "${XUI_SERVICE}"; then
            printf '  面板服務    %s運行中%s\n' "${C_GREEN}" "${C_RESET}"
        else
            printf '  面板服務    %s未運行%s\n' "${C_RED}" "${C_RESET}"
        fi
    else
        printf '  面板        %s未安裝%s\n' "${C_YELLOW}" "${C_RESET}"
    fi

    if [[ -n ${PANEL_PORT} ]]; then
        if port_in_use "${PANEL_PORT}"; then
            printf '  面板端口    %s  %s監聽中%s  %s\n' "${PANEL_PORT}" "${C_GREEN}" "${C_RESET}" "$(panel_access_url)"
        else
            printf '  面板端口    %s  %s未監聽%s\n' "${PANEL_PORT}" "${C_RED}" "${C_RESET}"
        fi
    fi

    if [[ -n ${REALITY_UUID} ]]; then
        if port_in_use "${REALITY_PORT}"; then
            printf '  節點端口    %s  %s監聽中%s（%s）\n' "${REALITY_PORT}" "${C_GREEN}" "${C_RESET}" "${REALITY_REMARK}"
        else
            printf '  節點端口    %s  %s未監聽%s\n' "${REALITY_PORT}" "${C_RED}" "${C_RESET}"
        fi
    fi

    if nat_mode; then
        printf '  NAT 映射    節點 %s → %s　面板 %s → %s\n' \
            "$(reality_public_port)" "${REALITY_PORT}" "$(panel_public_port)" "${PANEL_PORT}"
    fi

    if have ufw; then
        printf '  防火牆      %s\n' "$(ufw status 2>/dev/null | awk 'NR==1{sub(/^Status: /,""); print; exit}' || echo '未知')"
    elif have firewall-cmd; then
        printf '  防火牆      firewalld %s\n' "$(systemctl is-active firewalld 2>/dev/null || true)"
    fi

    if have fail2ban-client; then
        printf '  Fail2ban    %s\n' "$(systemctl is-active fail2ban 2>/dev/null || true)"
        fail2ban-client status sshd 2>/dev/null | sed -n 's/.*Currently banned:[[:space:]]*/  已封鎖 IP   /p; s/.*Total banned:[[:space:]]*/  累計封鎖   /p'
    fi

    printf '  BBR         %s / %s\n' \
        "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')" \
        "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"

    local latest
    latest=$(find "${BACKUP_DIR}" -maxdepth 1 -type f -name 'xui-shield-backup-*.tar.gz' \
        -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f2- || true)
    if [[ -n ${latest} ]]; then
        printf '  最近備份    %s  %s\n' "$(basename "${latest}")" "$(du -h "${latest}" 2>/dev/null | awk '{print $1}')"
    else
        printf '  最近備份    %s無%s\n' "${C_YELLOW}" "${C_RESET}"
    fi
    if systemctl is-active --quiet xui-shield-backup.timer; then
        printf '  備份定時    %s\n' "$(systemctl list-timers xui-shield-backup.timer --no-pager 2>/dev/null | awk 'NR==2{print $1, $2, $3}')"
    fi

    printf '  磁盤        %s\n' "$(df -h / | awk 'NR==2{print $3" / "$2" ("$5")"}')"
    hr "─" 60
    printf '  面板：%s\n' "$(panel_access_url 2>/dev/null || echo '-')"
    [[ -f ${CLIENT_LINK_FILE} ]] && printf '  客戶端資訊：%s\n' "${CLIENT_LINK_FILE}"
    printf '\n  %s需要香港動態 IP NAT VPS / 代部署？%s %s%s%s · %s%s%s\n\n' \
        "${C_DIM}" "${C_RESET}" "${C_BOLD}${C_NEON}" "${BRAND_TG}" "${C_RESET}" \
        "${C_BOLD}${C_GOLD}" "${BRAND_SITE_URL}" "${C_RESET}"
}

# ---------------------------------------------------------------------------
# 還原
# ---------------------------------------------------------------------------
do_restore() {
    local file="${1:-}"
    [[ -n ${file} ]] || die "請指定備份檔：--restore /path/to/xui-shield-backup-xxxx.tar.gz"
    [[ -r ${file} ]] || die "無法讀取備份檔：${file}"

    tar -tzf "${file}" >/dev/null 2>&1 || die "備份檔損壞或格式不正確：${file}"
    tar -tzf "${file}" | grep -q '^\./x-ui.db$' || die "備份檔內找不到 x-ui.db。"

    warn "還原會覆蓋 /etc/x-ui/x-ui.db，現有面板資料（用戶、節點）會被取代。"
    confirm "確定要還原 ${file} 嗎？" "n" || { say "已取消。"; return 0; }

    local tmp
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '${tmp}'" EXIT

    tar -xzf "${file}" -C "${tmp}" || die "解壓失敗。"

    local stamp
    stamp=$(date +%Y%m%d-%H%M%S)
    install -d -m 700 "${BACKUP_DIR}"
    cp -a "${XUI_DB}" "${BACKUP_DIR}/pre-restore-${stamp}.db" 2>/dev/null || true

    systemctl stop "${XUI_SERVICE}" >>"${LOG_FILE}" 2>&1 || true
    cp -a "${tmp}/x-ui.db" "${XUI_DB}"
    chown root:root "${XUI_DB}"
    chmod 600 "${XUI_DB}"

    if [[ -d ${tmp}/etc-x-ui ]]; then
        cp -a "${tmp}/etc-x-ui/." /etc/x-ui/ 2>/dev/null || true
    fi

    local t
    for t in certs-root.tar.gz certs-xui.tar.gz; do
        if [[ -f ${tmp}/${t} ]]; then
            tar -xzf "${tmp}/${t}" -C / 2>/dev/null || warn "還原 ${t} 失敗，憑證可能要用戶手動處理。"
        fi
    done

    systemctl start "${XUI_SERVICE}" >>"${LOG_FILE}" 2>&1 ||
        die "還原後面板啟動失敗。原資料庫已備份到 ${BACKUP_DIR}/pre-restore-${stamp}.db"

    local pport="${PANEL_PORT}"
    if [[ -z ${pport} ]]; then
        pport=$("${XUI_BIN}" setting -show true 2>/dev/null |
            awk -F': ' '/^port:/ { print $2; exit }')
    fi
    if [[ -n ${pport} ]]; then
        wait_port "${pport}" 40 || warn "面板端口未監聽，請檢查 journalctl -u x-ui。"
    fi
    ok "還原完成。原資料庫：${BACKUP_DIR}/pre-restore-${stamp}.db"
}

# ---------------------------------------------------------------------------
# 卸載本腳本新增的內容（保留 3x-ui 和資料）
# ---------------------------------------------------------------------------
do_uninstall() {
    warn "會移除：備份定時器、Fail2ban 自訂 jail、內核參數檔、防火牆回滾工具、xui-shield 命令。"
    warn "不會移除：3x-ui 面板、資料庫、備份檔、UFW 本身。"
    confirm "確定要卸載 xui-shield 的系統設定嗎？" "n" || { say "已取消。"; return 0; }

    systemctl disable --now xui-shield-backup.timer >>"${LOG_FILE}" 2>&1 || true
    rm -f /etc/systemd/system/xui-shield-backup.timer \
        /etc/systemd/system/xui-shield-backup.service
    rm -f "${BACKUP_HELPER}" "${FW_GUARD_BIN}"
    rm -f /etc/systemd/system/x-ui.service.d/20-xui-shield-limits.conf 2>/dev/null || true
    rmdir /etc/systemd/system/x-ui.service.d 2>/dev/null || true
    rm -f "${F2B_JAIL_FILE}"
    rm -f "${SYSCTL_FILE}"
    systemctl daemon-reload >>"${LOG_FILE}" 2>&1 || true
    systemctl restart fail2ban >>"${LOG_FILE}" 2>&1 || true
    sysctl --system >>"${LOG_FILE}" 2>&1 || true
    systemctl stop xui-shield-fw-guard.timer >/dev/null 2>&1 || true
    systemctl reset-failed xui-shield-fw-guard.service >/dev/null 2>&1 || true
    rm -f "${SELF_PATH}" 2>/dev/null || true

    ok "已移除 xui-shield 系統設定。面板和備份檔仍然保留。"
    say "如需重新部署：${INSTALL_CMD}"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
generate_defaults() {
    if [[ -z ${PANEL_PORT} ]]; then
        local i p
        for ((i = 0; i < 80; i++)); do
            p=$(((RANDOM % 50000) + 10000))
            [[ ${p} == "${REALITY_PORT}" ]] && continue
            if ! port_in_use "${p}"; then
                PANEL_PORT="${p}"
                break
            fi
        done
        [[ -n ${PANEL_PORT} ]] || die "無法自動選擇面板端口，請用 --panel-port 指定。"
    fi
    [[ -n ${PANEL_PATH} ]] || PANEL_PATH=$(rand_hex 6)
    [[ -n ${PANEL_USER} ]] || PANEL_USER="ns$(rand_alnum 6)"
    [[ -n ${PANEL_PASS} ]] || PANEL_PASS=$(rand_alnum 24)
}

validate_inputs() {
    if ! [[ ${REALITY_PORT} =~ ^[0-9]+$ ]] || ((REALITY_PORT < 1 || REALITY_PORT > 65535)); then
        die "節點端口無效：${REALITY_PORT}"
    fi
    if ! [[ ${PANEL_PORT} =~ ^[0-9]+$ ]] || ((PANEL_PORT < 1 || PANEL_PORT > 65535)); then
        die "面板端口無效：${PANEL_PORT}"
    fi
    ((PANEL_PORT != REALITY_PORT)) || die "面板端口不可以與節點端口相同。"
    if [[ -n ${REALITY_PUBLIC_PORT} ]]; then
        if ! [[ ${REALITY_PUBLIC_PORT} =~ ^[0-9]+$ ]] ||
            ((REALITY_PUBLIC_PORT < 1 || REALITY_PUBLIC_PORT > 65535)); then
            die "對外節點端口無效：${REALITY_PUBLIC_PORT}"
        fi
    fi
    if [[ -n ${PANEL_PUBLIC_PORT} ]]; then
        if ! [[ ${PANEL_PUBLIC_PORT} =~ ^[0-9]+$ ]] ||
            ((PANEL_PUBLIC_PORT < 1 || PANEL_PUBLIC_PORT > 65535)); then
            die "對外面板端口無效：${PANEL_PUBLIC_PORT}"
        fi
    fi
    if [[ -n ${REALITY_PUBLIC_PORT} && -n ${PANEL_PUBLIC_PORT} ]] &&
        ((REALITY_PUBLIC_PORT == PANEL_PUBLIC_PORT)); then
        die "對外節點端口與對外面板端口不可以相同。"
    fi
    if [[ -n ${PUBLIC_HOST} ]]; then
        [[ ${PUBLIC_HOST} =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
            die "對外主機格式無效：${PUBLIC_HOST}（只能是域名或 IPv4）"
    fi
    [[ ${REALITY_SNI} =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
        die "SNI 格式無效：${REALITY_SNI}（只能是域名）"
    [[ ${BACKUP_KEEP} =~ ^[0-9]+$ ]] || die "保留天數必須是數字。"
    [[ ${BACKUP_TIME} =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] ||
        die "備份時間格式錯誤：${BACKUP_TIME}"
}

run_install() {
    if ((FORCE_PANEL_RESET == 1)); then
        PANEL_PORT=""
        PANEL_PATH=""
        PANEL_USER=""
        PANEL_PASS=""
    fi
    generate_defaults
    validate_inputs

    install_packages
    install_panel
    apply_panel_settings
    setup_panel_tls
    restart_panel
    apply_xui_limits
    create_reality_inbound

    if [[ -n ${REALITY_UUID} ]]; then
        write_client_info
    fi
    save_config

    stage_firewall
    setup_fail2ban
    apply_sysctl
    install_backup_timer

    verify_all
    print_report
    prompt_firewall_confirm
    print_ad_board
}

main() {
    load_config
    parse_args "$@"

    require_root

    case "${ACTION}" in
        check | uninstall) ;;
        *) install_self ;;
    esac

    case "${ACTION}" in
        status)
            show_status
            exit 0
            ;;
        confirm-fw)
            confirm_firewall
            exit 0
            ;;
        restore)
            do_restore "${RESTORE_FILE}"
            exit 0
            ;;
        uninstall)
            do_uninstall
            exit 0
            ;;
    esac

    WORKDIR=$(mktemp -d /tmp/xui-shield.XXXXXX)
    # shellcheck disable=SC2064
    trap "rm -rf '${WORKDIR}'" EXIT

    banner

    if [[ ${ACTION} == "check" ]]; then
        preflight
        printf '\n'
        ok "環境檢查完成，沒有改動任何系統設定。"
        say "可以正式執行：${INSTALL_CMD}"
        exit 0
    fi

    case "${ACTION}" in
        firewall)
            detect_os
            detect_ssh_ports
            stage_firewall
            prompt_firewall_confirm
            print_ad_board
            ;;
        backup | backup-run)
            detect_os
            if ! have sqlite3; then
                if [[ ${PKG} == "apt" ]]; then
                    pkg_install sqlite3 >>"${LOG_FILE}" 2>&1 ||
                        die "需要 sqlite3 才能備份，但安裝失敗。"
                else
                    pkg_install sqlite >>"${LOG_FILE}" 2>&1 ||
                        die "需要 sqlite3 才能備份，但安裝失敗。"
                fi
            fi
            if [[ ! -x ${BACKUP_HELPER} ]]; then
                install_backup_timer
            else
                info "執行備份 …"
                "${BACKUP_HELPER}"
            fi
            ;;
        install)
            preflight
            if [[ -n ${PANEL_DOMAIN} ]]; then
                info "面板域名：${PANEL_DOMAIN}（憑證仍為自簽，需自行將域名指向本機）"
            fi
            run_install
            ;;
        *)
            die "未知動作：${ACTION}"
            ;;
    esac
}

main "$@"

