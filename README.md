# XUI-SHIELD

> 3x-ui 一鍵抗封鎖面板脚本 + 自動化防火牆防禦 + 每日備份  
> 作者 **NatShift-N** · Telegram [@NatShift](https://t.me/NatShift) · VPS 官網 [hkvps.xyz](https://hkvps.xyz)  
> 香港動態 IP NAT VPS · PVE / KVM 全虛擬化 · 每天自動更換 IP

一支 bash 腳本，把「面板 → 節點 → 防火牆 → 防爆破 → 加速 → 備份」一次完成，
而且**不會鎖死你的 SSH**。適合新購買的 VPS 在十分鐘內上線，也適合已經有 3x-ui 的機器補上防火牆和備份。
針對香港動態 IP NAT VPS 額外支援端口映射與 DDNS 域名。

```bash
bash xui-shield.sh
```

---

## 目錄

- [它會做什麼](#它會做什麼)
- [快速開始](#快速開始)
- [系統需求](#系統需求)
- [常用指令](#常用指令)
- [參數一覽](#參數一覽)
- [部署之後](#部署之後)
- [防火牆安全機制（重要）](#防火牆安全機制重要)
- [備份與還原](#備份與還原)
- [更換真憑證 / 接入 CDN](#更換真憑證--接入-cdn)
- [抗封鎖原理與限制](#抗封鎖原理與限制)
- [常見問題](#常見問題)
- [日誌與排錯](#日誌與排錯)
- [自訂品牌與推廣](#自訂品牌與推廣)
- [授權與免責](#授權與免責)

---

## 它會做什麼

| # | 模組 | 內容 |
|---|------|------|
| 1 | **3x-ui 面板** | 由官方安裝器安裝、隨機端口（10000–60000）、12 位隨機路徑、隨機帳號密碼、自簽 HTTPS |
| 2 | **抗封鎖節點** | VLESS + Reality（TCP）、`xtls-rprx-vision`、uTLS `chrome` 指紋、SNI 偽裝、sniffing |
| 3 | **自動化防火牆** | UFW 或 firewalld、預設拒絕傳入、SSH 限速、只放行必要端口、**15 分鐘自動回滾** |
| 4 | **防爆破** | Fail2ban sshd jail（4 次失敗即封鎖 24 小時） |
| 5 | **加速 / 加固** | BBR + fq、TCP 參數、`LimitNOFILE=1048576` |
| 6 | **每日備份** | SQLite 一致性快照 + 憑證 + 設定 → `.tar.gz` + SHA256、保留 14 天、可選 Telegram 上傳 |
| 7 | **NAT / 動態 IP** | 對外端口映射、DDNS 域名、部署後連通性自檢、NAT keepalive；每天換 IP 後客戶端仍可用域名連線 |

設計原則：

- **只新增規則，不 reset**：不會清除你原有的 UFW / firewalld / 網站。
- **可重複執行**：已經安裝過的會沿用，不會重新安裝、不會覆蓋你原有節點。
- **出錯有交代**：失敗會顯示階段、原因、日誌位置，以及如何尋求協助。

---

## 快速開始

### 方法 A：上傳後執行（推薦）

```bash
# 在你的電腦上
scp xui-shield.sh root@你的伺服器IP:/root/

# SSH 登入伺服器
ssh root@你的伺服器IP
bash /root/xui-shield.sh
```

### 方法 B：託管後一鍵（自行上傳到你的網站）

```bash
bash <(curl -fsSL https://你的域名/xui-shield.sh)
```

### 方法 C：發布到 GitHub 後一鍵

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<你的帳號>/xui-shield/main/xui-shield.sh)
```

> 把 `<你的帳號>` 換成 GitHub 使用者名稱即可。建議同時建立 `v1.0.0` 標籤，
> 之後可以用固定版本連結，避免 `main` 更新影響舊部署。

> 用 `bash <(curl ...)` 執行時，腳本沒有本體檔案，`--backup-only` 之類功能仍可用，
> 但建議先下載再執行，方便日後重新執行和更新。

### 建議先做一次檢查（不改系統）

```bash
bash xui-shield.sh --check
```

它會檢查：系統版本、套件管理器、SSH 端口、記憶體 / 磁盤、時間同步、GitHub 連線、現有 3x-ui，以及是否為 NAT 網絡。

---

## NAT VPS 與每日換 IP（重點）

本腳本特別針對「香港動態 IP NAT VPS」設計：

- **PVE / KVM 全虛擬化**：有獨立內核，BBR、systemd、UFW / firewalld 都可正常運作，不是 LXC / OpenVZ 容器。
- **每天自動更換 IP**：適合對抗 IP 被封。但 IP 一換，所有寫死 IP 的節點連結都會失效，所以**必須使用 DDNS 域名**。
- **共享 IPv4 + 端口映射**：NAT VPS 的對外端口通常不是 443，而是服務商分配的端口（例如 24567）。腳本需要知道「對外端口 → 內網端口」的對應。

### 為什麼一般腳本在 NAT VPS 會失敗

多數一鍵腳本預設「獨立公網 IP + 443 + IP 固定」，但 NAT VPS 通常是：

- 共享 IPv4，對外端口由服務商分配（不是 443）。
- 內網端口 ≠ 對外端口。
- IP 每天更換。

結果是：腳本跑得完，但生成的 `vless://` 連結端口錯誤，客戶端連不上；或者第二天換 IP 後全部失效。

### 腳本已做的 NAT 適配

- **內外端口分離**：連結與面板 URL 自動使用 `--public-port` / `--panel-public-port`。
- **自動偵測 NAT**：內網 IP 與公網 IP 不一致時提示，避免用錯地址。
- **DDNS 域名**：`--public-host` 支援域名，自簽憑證 SAN 一併加入。
- **端口衝突提示**：端口被佔用而自動改動時，提醒同步更新服務商映射。
- **防火牆只開內網端口**：對外端口由服務商映射，不會誤開。
- **部署後連通性自檢**：自動測試對外端口；hairpin 失敗會列出可能原因。
- **NAT keepalive**：縮短 TCP keepalive，減少空閒映射過期造成的斷線。
- **BBR + fq**：PVE / KVM 完整內核可正常生效，共享 IPv4 環境下改善吞吐。

### 部署範例

假設服務商分配：

| 用途 | 內網端口 | 對外端口 |
|---|---|---|
| Reality | 443 | 24567 |
| 面板 | 12345 | 24568 |

```bash
bash xui-shield.sh \
  --public-host node.example.com \
  --public-port 24567 \
  --panel-public-port 24568
```

- `--public-host`：客戶端與瀏覽器實際連接的域名。請用 DDNS 指向每天的新 IP。
- `--public-port`：Reality 的對外端口。
- `--panel-public-port`：面板的對外端口。
- 防火牆只需要放行**內網端口**（443、12345）；對外映射由服務商面板負責。
- SSH 也可能有對外端口映射；連接時請用 `ssh -p <對外端口> root@<共享 IP>`，`scp` 用 `-P <對外端口>`。
- 部分 NAT 服務商的出入站 IP 可能不同；腳本偵測到的公網 IP 未必是客戶端應連接的 IP，請以服務商提供的共享 IP / 主機名為準。

### DDNS 建議

- 使用 Cloudflare、DNSPod、ddns-go、RouterOS 等，把 `node.example.com` 自動指向目前 IP。
- TTL 設低（約 60 秒），換 IP 後客戶端可以較快恢復。
- 如果服務商提供固定的共享主機名，也可以直接填入 `--public-host`。

### NAT 限制

- NAT VPS 是共享 IPv4，無法獨佔 80 / 443，也不適合直接做 CDN 回源。
- 部分服務商不支援 UDP 或端口段，下單前請確認。
- 每天換 IP 期間可能短暫中斷，恢復時間取決於 DDNS 的 TTL 與服務商。
- 若出入站 IP 不同，或服務商使用共享主機名，請以 `--public-host` 指定實際可連接的地址。

---

## 系統需求

| 項目 | 要求 |
|------|------|
| 系統 | Debian 11/12、Ubuntu 20.04/22.04/24.04、RHEL / Rocky / AlmaLinux 8+、CentOS 7+ |
| 架構 | x86_64、arm64、armv7（跟隨 3x-ui 官方支援） |
| 權限 | root |
| 記憶體 | 建議 512MB 以上（256MB 可運行，但容易 OOM） |
| 磁盤 | 至少 700MB 可用 |
| 網絡 | 需要連到 GitHub；NAT VPS 需先知道服務商分配的對外端口 |
| 初始化 | 需要 systemd |

> OpenVZ / LXC 通常改不到 BBR，腳本會自動跳過並提示，不會失敗。  
> PVE / KVM 有完整內核，BBR 與防火牆功能都可以正常使用。

---

## 常用指令

```bash
bash xui-shield.sh                     # 一鍵完整部署
bash xui-shield.sh --status            # 查看面板 / 節點 / 防火牆 / 備份狀態
bash xui-shield.sh --check             # 只檢查環境，不改系統
bash xui-shield.sh --firewall-only     # 只重新套用防火牆 + Fail2ban
bash xui-shield.sh --backup-only       # 立即手動備份一次
bash xui-shield.sh --confirm-firewall  # 確認保留防火牆（取消 15 分鐘自動回滾）
bash xui-shield.sh --restore /var/backups/x-ui/xui-shield-backup-20250101-043000.tar.gz
bash xui-shield.sh --uninstall         # 移除本腳本新增的定時器 / jail / 內核參數（保留面板）
```

---

## 參數一覽

### 面板

| 參數 | 說明 |
|------|------|
| `--panel-port N` | 指定面板端口（預設隨機） |
| `--panel-domain D` | 用域名訪問面板（憑證仍為自簽，需自行將域名指向本機） |
| `--no-panel-tls` | 面板只用 HTTP（除非你有反向代理，否則不建議） |
| `--panel-tls` | 面板使用 HTTPS（預設） |
| `--local-panel` | 面板只綁定 `127.0.0.1`，用 SSH 隧道訪問（最安全） |
| `--public-panel` | 面板改回綁定 `0.0.0.0` |
| `--force-panel-reset` | 重設面板帳號 / 密碼 / 端口 / 路徑（舊連結會失效） |
| `--reinstall` | 強制重新安裝 3x-ui（資料庫保留） |

### 節點

| 參數 | 說明 |
|------|------|
| `--port N` | Reality 監聽端口（預設 443；被佔用時自動改用高位端口） |
| `--sni HOST` | Reality 偽裝目標（預設 `www.microsoft.com`） |

### NAT / 動態 IP

| 參數 | 說明 |
|------|------|
| `--public-host HOST` | 對外訪問用的域名或 IP（每天換 IP 建議填 DDNS 域名） |
| `--public-port N` | Reality 對外映射端口（NAT VPS 用；預設等於內網端口） |
| `--panel-public-port N` | 面板對外映射端口（NAT VPS 用；預設等於內網端口） |

### 防火牆 / 備份

| 參數 | 說明 |
|------|------|
| `--no-firewall` | 不改防火牆 |
| `--no-fail2ban` | 不安裝 Fail2ban |
| `--no-bbr` | 不改 BBR / 內核參數 |
| `--no-backup` | 不設定每日備份 |
| `--backup-dir DIR` | 備份目錄（預設 `/var/backups/x-ui`） |
| `--backup-time HH:MM` | 每日備份時間（預設 `04:30`，伺服器本地時間） |
| `--keep N` | 保留天數（預設 14） |
| `--tg-token TOKEN` | Telegram Bot Token，備份自動上傳 |
| `--tg-chat ID` | Telegram Chat ID |

### 其他

| 參數 | 說明 |
|------|------|
| `-y`, `--yes` | 不詢問，直接執行（並自動確認保留防火牆） |
| `--debug` | 顯示除錯資訊 |
| `-h`, `--help` | 說明 |
| `-V`, `--version` | 版本 |

### 例子

```bash
# 443 被 nginx 佔用？改用 8443，順便更換 SNI
bash xui-shield.sh --port 8443 --sni www.apple.com

# 香港動態 IP NAT VPS：對外 24567 → 內網 443，對外 24568 → 內網 12345
bash xui-shield.sh \
  --public-host node.example.com \
  --public-port 24567 \
  --panel-public-port 24568

# 最高安全：面板只監聽 localhost，之後用隧道
bash xui-shield.sh --local-panel
ssh -L 8080:127.0.0.1:12345 root@你的IP
# 瀏覽器開啟 https://127.0.0.1:8080/路徑/

# 換機：舊機備份 → 新機還原
bash xui-shield.sh --backup-only
scp /var/backups/x-ui/xui-shield-backup-*.tar.gz root@新機:/root/
bash xui-shield.sh --restore /root/xui-shield-backup-xxxx.tar.gz
```

---

## 部署之後

執行完成後你會看到：

```
面板      https://node.example.com:24568/AbCdEf123456/
帳號      nsxxxxxx
密碼      ************************
節點      vless://...@node.example.com:24567（VLESS + Reality）
防火牆    UFW · SSH 22 · 面板 12345 · 節點 443（內網）
NAT       對外 24567 → 內網 443；對外 24568 → 內網 12345
備份      每日 04:30 · 保留 14 天 · /var/backups/x-ui
```

同時會寫入：

| 路徑 | 內容 | 權限 |
|------|------|------|
| `/root/xui-shield-client.txt` | 面板網址、帳號密碼、節點連結、UUID / PublicKey | 600 |
| `/etc/xui-shield/config.env` | 部署參數（重新執行時沿用） | 600 |
| `/var/log/xui-shield.log` | 完整執行日誌 | root |
| `/var/backups/x-ui/` | 每日備份 | 700 |

### 登入面板

1. 開啟 `https://你的域名:對外面板端口/路徑/`。
2. 自簽憑證會提示「不安全」→ 進階 → 繼續前往。
3. 用終端機顯示的帳號密碼登入。

### 導入節點

- 複製 `vless://...` 連結，貼入 v2rayN / v2rayNG / Shadowrocket / NekoBox 等客戶端。
- 或者用 `/root/xui-shield-client.txt` 內的 UUID、PublicKey、ShortId 手動填。

### 想更換真憑證

```bash
# 例如用 acme.sh 簽發完成之後
cp /root/cert/你的域名/fullchain.pem /etc/x-ui/cert/panel.crt
cp /root/cert/你的域名/privkey.pem   /etc/x-ui/cert/panel.key
chmod 600 /etc/x-ui/cert/panel.key
x-ui restart
```

> 只要 `/etc/x-ui/cert/panel.crt` 和 `panel.key` 存在，重新執行腳本會沿用，不會覆蓋。

---

## 防火牆安全機制（重要）

遠程改防火牆最怕「修改後連自己都無法重新進入」。這支腳本採用四層保護：

1. **精準偵測 SSH 端口**
   由 `$SSH_CONNECTION`、`sshd -T`、`sshd_config` / `sshd_config.d/*.conf` 聯集所有 SSH 端口，
   任何一個都一定會放行；偵測失敗就預設 22。
2. **只新增、不清除**
   不會 `ufw reset`。你原有的網站規則（80/443）會被保留。
3. **開啟前後雙重檢查**
   啟用前確認 SSH 規則存在；啟用後再查一次，不見了就立即關閉防火牆。
4. **15 分鐘自動回滾**
   啟用 UFW 後會啟動一個 systemd timer。如果 15 分鐘內沒有確認，就自動 `ufw disable`，
   讓你可以重新登入並進行救援。

確認方式（三選一）：

- 執行完成時按 Enter（互動模式）；
- `bash xui-shield.sh --confirm-firewall`；
- `-y` 會自動確認。

> 如果 UFW 本身已經啟用，腳本**不會**在回滾時關閉你原有防火牆（避免影響你其他服務）。

其他細節：

- SSH 使用 `ufw limit`（同 IP 30 秒內最多 6 次新連線），大幅減少暴力破解。
- 面板端口不做 limit，避免面板 UI 一次建立多條連線時受到影響。
- 偵測到 Docker 會提示：容器 publish 出來的端口會繞過 UFW，建議綁定 `127.0.0.1`
  或自行加入 `DOCKER-USER` 規則。
- NAT VPS 只需放行**內網端口**；對外端口由服務商映射，腳本會用 `--public-port` 顯示正確連結。
- NAT VPS 的 SSH 也可能有對外端口映射；腳本只偵測內網 SSH 端口，外部端口請依服務商說明連接。
- 支援 IPv6（會將 `/etc/default/ufw` 設為 `IPV6=yes`）。

---

## 備份與還原

### 備份內容

每次備份會打包：

```
x-ui.db                 # SQLite 一致性快照（.backup，不會鎖住面板）
etc-x-ui/               # 憑證、設定（不含 db）
certs-root.tar.gz       # /root/cert（如有）
certs-xui.tar.gz        # /usr/local/x-ui/cert（如有）
meta/                   # 版本、監聽端口、UFW、Fail2ban、sysctl、面板設定
SHA256SUMS              # 完整性校驗
```

檔名：`/var/backups/x-ui/xui-shield-backup-YYYYmmdd-HHMMSS.tar.gz`（權限 600）。

### 定時器

```bash
systemctl list-timers xui-shield-backup.timer
systemctl status xui-shield-backup.service
journalctl -u xui-shield-backup -n 50
```

修改時間 / 保留天數：

```bash
bash xui-shield.sh --backup-time 03:15 --keep 30
```

### 還原

```bash
bash xui-shield.sh --restore /var/backups/x-ui/xui-shield-backup-20250101-043000.tar.gz
```

還原前會自動將現有資料庫備份到 `pre-restore-*.db`，所以不會全部丟失。

### Telegram 備份（可選）

```bash
bash xui-shield.sh --tg-token 123456:ABC... --tg-chat 123456789
```

之後每次備份都會用 `sendDocument` 上傳到你的 TG。上傳失敗不會影響本地備份。

---

## 更換真憑證 / 接入 CDN

Reality 本身不需要域名和憑證，這是它抗封鎖的原因之一。
但如果你**面板**想使用真憑證：

1. 將域名 A 記錄指向伺服器；
2. 用 acme.sh / certbot 簽發（HTTP-01 需要 80 端口，記得防火牆放行）；
3. 將 `fullchain.pem` / `privkey.pem` 覆蓋到 `/etc/x-ui/cert/panel.crt|key`；
4. `x-ui restart`。

想接 CDN：

- Reality **不適合**直接接入 CDN（它依賴 TLS 指紋和 dest）。
- 需要 CDN 的話，另外啟動一個 VLESS + WS + TLS 節點，使用真憑證，再在 CDN 指向該端口。
- 面板本身不建議接入 CDN（多一層指紋和登入風險）。

---

## 抗封鎖原理與限制

**已實施的機制：**

- **Reality**：客戶端與伺服器做真實 TLS 握手，但證書由目標網站（例如 `www.microsoft.com`）提供，
  中間人看起來就是在訪問微軟。伺服器不需要擁有域名或憑證。
- **uTLS `chrome` 指紋**：TLS ClientHello 模仿 Chrome，減少指紋特徵。
- **`xtls-rprx-vision`**：減少 TLS-in-TLS 特徵和額外開銷。
- **隨機面板端口 / 路徑**：減少被掃描器直接命中面板。
- **每日更換 IP + DDNS**：IP 被針對時由服務商每天更換，客戶端透過域名自動跟隨新 IP。
- **無 open proxy 特徵**：Reality 不存在「未授權訪問會返回代理錯誤」的指紋。

**限制（請如實了解）：**

- 沒有任何方案「保證永久不被封」。IP 被封、端口被針對、SNI 被列入名單，都可能發生。
- Reality 的 `dest` / SNI 要選擇**你伺服器連得到、而且當地沒有被完全阻斷**的 TLS 1.3 網站。
  預設 `www.microsoft.com` 只是一個起點，不是萬能。
- 如果伺服器 IP 已被重點關注，更換 SNI 幫助有限，需要更換 IP（動態 IP 方案）或改用其他線路。
- 每天更換 IP 期間可能短暫中斷；客戶端必須使用 DDNS 域名，否則每次換 IP 都要重新分發連結。
- NAT VPS 是共享 IPv4，不能獨佔 80 / 443，也不適合直接做 CDN 回源。
- 本腳本不會幫你隱藏「你正在使用代理」的流量體積特徵；大量並發仍可能被 QoS。

> 這些正是可以付費解決的部分：**HKVPS 的香港動態 IP NAT VPS 方案**。

---

## 常見問題

**Q：443 已經被 nginx / 網站佔用？**  
A：腳本會自動改用高位端口（例如 2xxxx），並保留你原有 80/443。也可以 `--port 8443` 指定。

**Q：安裝時卡住 / 連不到 GitHub？**  
A：`--check` 會先測試 GitHub。若伺服器在受限網絡，請先設定代理或改用能連 GitHub 的機器。

**Q：面板打開後顯示「憑證不安全」？**  
A：預設自簽憑證，屬正常。按「進階 → 繼續」即可；或按上面方法更換真憑證。

**Q：忘記面板密碼？**  
A：`x-ui` 菜單可重設；或 `bash xui-shield.sh --force-panel-reset`（會更換端口 / 路徑 / 帳號密碼）。

**Q：SSH 被鎖在外面？**  
A：等 15 分鐘自動回滾；或使用雲廠商 VNC / 救援模式執行 `ufw disable`。
（若 UFW 之前已啟用，回滾不會關閉，請用 VNC。）

**Q：OpenVZ 上 BBR 沒有生效？**  
A：正常，容器改不到內核參數。腳本會跳過，不影響節點。

**Q：NAT VPS 可以用 443 嗎？**  
A：對外 443 通常不可用，服務商會分配其他對外端口；內網仍可監聽 443，再用 `--public-port` 指定對外端口。

**Q：每天換 IP，客戶端怎麼辦？**  
A：用 DDNS 域名作為 `--public-host`，並確保 DDNS 會跟隨新 IP 更新；否則每次換 IP 都要重新分發節點連結。

**Q：PVE / KVM 與容器有什麼差別？**  
A：KVM 有獨立內核，BBR、防火牆、systemd 都能正常運作；LXC / OpenVZ 共用宿主內核，BBR 與部分 sysctl 可能無法使用。

**Q：NAT VPS 的端口映射要怎麼填？**  
A：在服務商面板查看「對外端口 → 內網端口」，把對外端口填入 `--public-port` 與 `--panel-public-port`；內網端口由腳本自動選擇。

**Q：可以安裝 Hysteria2 / TUIC 嗎？**  
A：3x-ui 支援，但本腳本只自動建立 Reality。你可以在面板手動新增，記得放行 UDP。

**Q：支援 Alpine？**  
A：暫不支援（Alpine 用 OpenRC + 沒有 UFW）。請用 Debian / Ubuntu。

**Q：重新執行會不會覆蓋我的節點？**  
A：不會。腳本只會新增「HK-Reality-<port>」這個 remark 的節點；已存在就跳過。

---

## 日誌與排錯

```bash
tail -n 100 /var/log/xui-shield.log          # 部署日誌
tail -n 100 /var/log/xui-shield-backup.log   # 備份日誌
journalctl -u x-ui -n 100 --no-pager         # 面板 / Xray
journalctl -u fail2ban -n 50 --no-pager      # Fail2ban
ufw status verbose                           # 防火牆規則
fail2ban-client status sshd                  # 被封 IP
x-ui log                                     # 3x-ui 內建日誌
```

失敗時腳本會顯示：

- 失敗的階段（packages / install / panel / reality / firewall / fail2ban / backup / sysctl / verify）
- 可能原因
- 日誌路徑
- 聯絡方式

把「終端機輸出 + `/var/log/xui-shield.log` 最後 50 行」貼給我們，可以最快定位。

---

## 自訂品牌與推廣

腳本頂部有一組 `BRAND_*` 變數：

```bash
BRAND_NAME="NatShift"
BRAND_TG="@NatShift"
BRAND_TG_URL="https://t.me/NatShift"
BRAND_SITE="hkvps.xyz"
BRAND_SITE_URL="https://hkvps.xyz"
```

修改完成後，以下三處會同步更新：

1. **原始碼標頭**的數位名片（版權 + 服務 + 聯絡）；
2. **終端機結尾**的彩色廣告看板；
3. **錯誤訊息**中的痛點推銷與支援入口。

另外 `print_failure_pitch()` 內可以按階段改文案，`print_ad_board()` 可以改廣告內容。

> 這三個位置是刻意設計的：查看原始碼時建立信任、成功時轉化、失敗時承接客戶。

---

## 授權與免責

- 本腳本採用 MIT 授權（見 `LICENSE`），可自由使用、修改、再分發；轉載時請保留作者與推廣資訊。
- 3x-ui、Xray-core 為其各自作者之開源項目，本腳本只負責自動化部署。
- 本工具僅供合法用途（自建代理、企業內網加速、跨境辦公、隱私保護等）。
  請自行確認並遵守你所在地區的法律法規；使用者需對自己的部署行為負責。
- 防火牆屬系統級操作，雖然已內建多重保護，仍建議在雲廠商控制台確認
  VNC / 救援模式可用後再執行。

---

## 聯絡 / 服務

| | |
|---|---|
| Telegram | [@NatShift](https://t.me/NatShift) |
| VPS 官網 | [hkvps.xyz](https://hkvps.xyz) |
| 服務 | 香港動態 IP NAT VPS（PVE / KVM 全虛擬化，不是容器）、每天自動更換 IP、3x-ui 代部署、節點調優、疑難排解、7x24 代維運 |

> 報錯時說明「用了 xui-shield」，會優先處理。
