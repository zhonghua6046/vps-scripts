#!/bin/sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_SHARE_DIR="/usr/local/share/xray"

cecho() { printf '%b\n' "$1"; }

if [ "$(id -u)" -ne 0 ]; then
    cecho "${RED}错误：请使用 root 或 sudo 运行此脚本。${PLAIN}"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    cecho "${RED}错误：未找到 $CONFIG_FILE${PLAIN}"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    cecho "${RED}错误：缺少 jq，请先安装 jq (如 apt install -y jq 或 apk add jq)。${PLAIN}"
    exit 1
fi

# 检测初始化系统
INIT_SYS="unknown"
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    INIT_SYS="systemd"
elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
    INIT_SYS="openrc"
fi

# 收紧 config.json 权限 (自动兼容 xray 组 / OpenRC / 旧版 nobody)
secure_config_permissions() {
    if grep -q '^xray:' /etc/group 2>/dev/null; then
        chown root:xray "$CONFIG_FILE"
        chmod 640 "$CONFIG_FILE"
    elif [ "$INIT_SYS" = "openrc" ] || grep -Eq '^User=root$' /etc/systemd/system/xray.service 2>/dev/null; then
        chown root:root "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
    else
        chown root:root "$CONFIG_FILE"
        chmod 644 "$CONFIG_FILE"
    fi
}

# 生成未占用的随机内网端口 (仅当旧配置无 dokodemo-in 时使用)
get_free_inner_port() {
    local ex1="${1:-}"
    local ex2="${2:-}"
    local p=""
    local i=0
    while [ "$i" -lt 30 ]; do
        if command -v shuf >/dev/null 2>&1; then
            p=$(shuf -i 20000-39999 -n 1)
        else
            p=$(awk -v s="$((i + $$))" 'BEGIN{srand(s); print int(20000+rand()*20000)}')
        fi
        if [ "$p" != "$ex1" ] && [ "$p" != "$ex2" ]; then
            if command -v ss >/dev/null 2>&1 && ss -tuln 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${p}$"; then
                i=$((i + 1))
                continue
            fi
            printf '%s' "$p"
            return 0
        fi
        i=$((i + 1))
    done
    printf '%s' "$p"
}

# === 1. 解析旧配置 (自动兼容 JSONC 注释与尾随逗号) ===
clean_cfg=$(mktemp)
awk '
{
    line = $0
    len = length(line)
    i = 1
    out = ""
    while (i <= len) {
        c = substr(line, i, 1)
        nextc = (i < len) ? substr(line, i + 1, 1) : ""
        if (in_block) {
            if (c == "*" && nextc == "/") {
                in_block = 0
                i += 2
            } else {
                i++
            }
        } else if (in_str) {
            out = out c
            if (c == "\\" && i < len) {
                out = out nextc
                i += 2
            } else if (c == "\"") {
                in_str = 0
                i++
            } else {
                i++
            }
        } else {
            if (c == "\"") {
                in_str = 1
                out = out c
                i++
            } else if (c == "/" && nextc == "/") {
                break
            } else if (c == "/" && nextc == "*") {
                in_block = 1
                i += 2
            } else {
                out = out c
                i++
            }
        }
    }
    buf = buf out "\n"
}
END {
    gsub(/,[ \t\r\n]*}/, "}", buf)
    gsub(/,[ \t\r\n]*\]/, "]", buf)
    printf "%s", buf
}' "$CONFIG_FILE" > "$clean_cfg"

if ! jq empty "$clean_cfg" 2>/dev/null; then
    cecho "${RED}错误：去除注释后仍无法解析 $CONFIG_FILE，请检查文件语法：${PLAIN}"
    jq empty "$clean_cfg"
    rm -f "$clean_cfg"
    exit 1
fi

reality_json=$(jq -c '.inbounds[] | select(.protocol == "vless" and .streamSettings.security == "reality")' "$clean_cfg" | head -n 1)
dokodemo_json=$(jq -c '.inbounds[] | select(.protocol == "dokodemo-door")' "$clean_cfg" | head -n 1)
ss_json=$(jq -c '.inbounds[] | select(.protocol == "shadowsocks")' "$clean_cfg" | head -n 1)
rm -f "$clean_cfg"

if [ -z "$reality_json" ] && [ -z "$ss_json" ]; then
    cecho "${RED}错误：未在旧配置中检测到 Reality 或 Shadowsocks 入站。${PLAIN}"
    exit 1
fi

has_reality="false"
has_ss="false"
[ -n "$reality_json" ] && has_reality="true"
[ -n "$ss_json" ] && has_ss="true"

# 提取 SS 参数
ss_port=""
if [ "$has_ss" = "true" ]; then
    ss_port=$(printf '%s' "$ss_json" | jq -r '.port')
    ss_method=$(printf '%s' "$ss_json" | jq -r '.settings.method')
    ss_password=$(printf '%s' "$ss_json" | jq -r '.settings.password')
    ss_network=$(printf '%s' "$ss_json" | jq -r '.settings.network // "tcp,udp"')
fi

# 提取 Reality 参数 (兼容旧版 dokodemo 在前、新版 vless 在前、以及无 dokodemo 三种情况)
if [ "$has_reality" = "true" ]; then
    reality_uuid=$(printf '%s' "$reality_json" | jq -r '.settings.clients[0].id')
    reality_flow=$(printf '%s' "$reality_json" | jq -r '.settings.clients[0].flow // "xtls-rprx-vision"')
    reality_sni=$(printf '%s' "$reality_json" | jq -r '.streamSettings.realitySettings.serverNames[0]')
    reality_private_key=$(printf '%s' "$reality_json" | jq -r '.streamSettings.realitySettings.privateKey // empty')
    reality_shortid=$(printf '%s' "$reality_json" | jq -r '.streamSettings.realitySettings.shortIds[0] // ""')

    if [ -z "$reality_private_key" ]; then
        cecho "${RED}错误：未能从旧配置中提取到 Reality 的 privateKey，已中止迁移！${PLAIN}"
        exit 1
    fi

    if [ -n "$dokodemo_json" ]; then
        d_addr=$(printf '%s' "$dokodemo_json" | jq -r '.settings.address')
        d_port=$(printf '%s' "$dokodemo_json" | jq -r '.settings.port')
        if [ "$d_addr" = "127.0.0.1" ]; then
            cecho "${CYAN}检测到旧版 Reality 架构 (dokodemo 在前)，将自动翻转为新版架构...${PLAIN}"
            reality_port=$(printf '%s' "$dokodemo_json" | jq -r '.port')
            reality_inner_port=$(printf '%s' "$reality_json" | jq -r '.port')
            raw_dest=$(printf '%s' "$reality_json" | jq -r '.streamSettings.realitySettings.dest // .streamSettings.realitySettings.target')
            case "$raw_dest" in
                *:*)
                    reality_dest_host=$(printf '%s' "$raw_dest" | cut -d: -f1)
                    reality_dest_port=$(printf '%s' "$raw_dest" | cut -d: -f2)
                    ;;
                *)
                    reality_dest_host="$raw_dest"
                    reality_dest_port="443"
                    ;;
            esac
        else
            cecho "${CYAN}检测到已是新版 Reality 架构，将保留参数并刷新路由规则...${PLAIN}"
            reality_port=$(printf '%s' "$reality_json" | jq -r '.port')
            reality_inner_port=$(printf '%s' "$dokodemo_json" | jq -r '.port')
            reality_dest_host="$d_addr"
            reality_dest_port="$d_port"
        fi
    else
        cecho "${CYAN}检测到纯 Reality 架构，将无损升级为新版防偷流量架构...${PLAIN}"
        reality_port=$(printf '%s' "$reality_json" | jq -r '.port')
        reality_inner_port=$(get_free_inner_port "$reality_port" "$ss_port")
        raw_dest=$(printf '%s' "$reality_json" | jq -r '.streamSettings.realitySettings.dest // .streamSettings.realitySettings.target')
        case "$raw_dest" in
            *:*)
                reality_dest_host=$(printf '%s' "$raw_dest" | cut -d: -f1)
                reality_dest_port=$(printf '%s' "$raw_dest" | cut -d: -f2)
                ;;
            *)
                reality_dest_host="$raw_dest"
                reality_dest_port="443"
                ;;
        esac
    fi
fi

# === 2. 展示提取到的参数并选择默认出口 ===
cecho "\n${GREEN}提取到的现有参数如下（将 100% 保持不变）：${PLAIN}"
if [ "$has_reality" = "true" ]; then
    reality_pbk=""
    reality_hash32=""
    if [ -x "$XRAY_BIN" ]; then
        x25519_out=$("$XRAY_BIN" x25519 -i "$reality_private_key" 2>/dev/null)
        reality_pbk=$(printf '%s\n' "$x25519_out" | grep -Ei "^(Public|Password)" | head -n 1 | cut -d: -f2 | tr -d ' \r\n')
        reality_hash32=$(printf '%s\n' "$x25519_out" | grep -Ei "^Hash32" | head -n 1 | cut -d: -f2 | tr -d ' \r\n')
    fi
    cecho "  [Reality] 外网端口=${reality_port} | 内网回落=${reality_inner_port} | 目标=${reality_dest_host}:${reality_dest_port} | SNI=${reality_sni}"
    cecho "            UUID=${reality_uuid} | ShortId=${reality_shortid}"
    cecho "            PrivateKey=${reality_private_key}"
    cecho "            Password (PublicKey)=${reality_pbk:-推导失败}"
    cecho "            Hash32=${reality_hash32:-未输出 (请检查内核版本)}"
fi
if [ "$has_ss" = "true" ]; then
    cecho "  [SS]      端口=${ss_port} | 加密=${ss_method} | 密码=${ss_password}"
fi

cecho "\n${GREEN}请选择迁移后的默认出站策略：${PLAIN}"
cecho "1. IPv4 出口 (IP4_out, 默认)"
cecho "2. IPv6 出口 (IP6_out)"
cecho "3. 系统自动适配 (direct, 适合纯 IPv6 或单栈机器)"
printf "请选择 [1-3] (默认 1): "
read -r out_choice
case "$out_choice" in
    2) default_outbound="IP6_out" ;;
    3) default_outbound="direct" ;;
    *) default_outbound="IP4_out" ;;
esac

# === 3. 生成新配置到临时 .json 文件 ===
raw_tmp=$(mktemp)
tmp_cfg="${raw_tmp}.json"
mv "$raw_tmp" "$tmp_cfg"

cat > "$tmp_cfg" <<EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
EOF

if [ "$has_reality" = "true" ]; then
    cat >> "$tmp_cfg" <<EOF
        {
            "port": $reality_port,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$reality_uuid",
                        "flow": "$reality_flow"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "127.0.0.1:$reality_inner_port",
                    "serverNames": [
                        "$reality_sni"
                    ],
                    "privateKey": "$reality_private_key",
                    "shortIds": [
                        "$reality_shortid"
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": true
            }
        },
        {
            "tag": "dokodemo-in",
            "listen": "127.0.0.1",
            "port": $reality_inner_port,
            "protocol": "dokodemo-door",
            "settings": {
                "address": "$reality_dest_host",
                "port": $reality_dest_port,
                "network": "tcp"
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["tls"],
                "routeOnly": true
            }
        }
EOF
fi

if [ "$has_reality" = "true" ] && [ "$has_ss" = "true" ]; then
    printf ',\n' >> "$tmp_cfg"
fi

if [ "$has_ss" = "true" ]; then
    cat >> "$tmp_cfg" <<EOF
        {
            "port": $ss_port,
            "protocol": "shadowsocks",
            "settings": {
                "method": "$ss_method",
                "password": "$ss_password",
                "network": "$ss_network"
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": true
            }
        }
EOF
fi

cat >> "$tmp_cfg" <<EOF
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        },
        {
            "tag": "IP4_out",
            "protocol": "freedom",
            "streamSettings": {
                "domainStrategy": "UseIPv4"
            }
        },
        {
            "tag": "IP6_out",
            "protocol": "freedom",
            "streamSettings": {
                "domainStrategy": "UseIPv6"
            }
        }
    ],
    "routing": {
        "rules": [
EOF

if [ "$has_reality" = "true" ]; then
    cat >> "$tmp_cfg" <<EOF
            {
                "inboundTag": [
                        "dokodemo-in"
                ],
                "domain": [
                    "$reality_sni"
                ],
                "outboundTag": "direct"
            },
            {
                "inboundTag": [
                        "dokodemo-in"
                ],
                "outboundTag": "block"
            },
EOF
fi

cat >> "$tmp_cfg" <<EOF
            {
                "domain": [
                    "geosite:google",
                    "domain:gstatic.com"
                ],
                "outboundTag": "$default_outbound"
            },
            {
                "domain": [
                    "geosite:cn",
                    "geoip:private"
                ],
                "outboundTag": "block"
            },
            {
                "ip": [
                    "geoip:cn"
                ],
                "outboundTag": "block"
            },
            {
                "network": "tcp,udp",
                "outboundTag": "$default_outbound"
            }
        ]
    }
}
EOF

# === 4. 校验、备份并原子替换 ===
cecho "\n${GREEN}正在校验新配置...${PLAIN}"
if ! XRAY_LOCATION_ASSET="$XRAY_SHARE_DIR" "$XRAY_BIN" run -test -config "$tmp_cfg"; then
    cecho "${RED}校验失败！已放弃迁移，原配置未做任何改动。${PLAIN}"
    rm -f "$tmp_cfg"
    exit 1
fi

backup_file="${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$CONFIG_FILE" "$backup_file"
chmod 600 "$backup_file"
mv "$tmp_cfg" "$CONFIG_FILE"
secure_config_permissions
cecho "${YELLOW}原配置已备份至: ${backup_file} (权限 600)${PLAIN}"

# 重启 Xray
if [ "$INIT_SYS" = "systemd" ]; then
    systemctl restart xray
    sleep 1
    if systemctl is-active --quiet xray; then
        cecho "${GREEN}迁移成功！Xray 已正常运行。${PLAIN}"
    else
        cecho "${RED}Xray 重启失败，请检查日志：journalctl -u xray -n 20${PLAIN}"
        exit 1
    fi
elif [ "$INIT_SYS" = "openrc" ]; then
    rc-service xray restart
    sleep 1
    if rc-service xray status >/dev/null 2>&1; then
        cecho "${GREEN}迁移成功！Xray 已正常运行。${PLAIN}"
    else
        cecho "${RED}Xray 重启失败，请运行 rc-service xray status 检查。${PLAIN}"
        exit 1
    fi
fi
