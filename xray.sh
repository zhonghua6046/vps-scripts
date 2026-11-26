#!/bin/sh

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 核心路径定义
CONFIG_FILE="/usr/local/etc/xray/config.json"
INFO_FILE="/usr/local/etc/xray/node_info.env"
XRAY_BIN="/usr/local/bin/xray"
XRAY_SHARE_DIR="/usr/local/share/xray"

# 跨平台彩色输出封装 (兼容 ash / dash / bash)
cecho() {
    printf '%b\n' "$1"
}

# 暂停并返回主菜单
pause_and_return() {
    printf '\n按回车键返回主菜单...'
    read -r _
}

# 检查是否为 Root
if [ "$(id -u)" -ne 0 ]; then
    cecho "${RED}错误: 必须使用 root 用户或 sudo 运行此脚本！${PLAIN}"
    exit 1
fi

# 检测包管理器与初始化系统 (systemd / openrc)
PKG_MGR="unknown"
INIT_SYS="unknown"

detect_system() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MGR="pacman"
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MGR="zypper"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"
    fi

    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        INIT_SYS="systemd"
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        INIT_SYS="openrc"
    fi
}

# 统一服务管理封装
service_enable_and_restart() {
    if [ "$INIT_SYS" = "systemd" ]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable xray >/dev/null 2>&1
        systemctl restart xray
    elif [ "$INIT_SYS" = "openrc" ]; then
        rc-update add xray default >/dev/null 2>&1
        rc-service xray restart
    else
        cecho "${RED}错误：未检测到 systemd 或 OpenRC，无法自动托管 Xray 服务。${PLAIN}"
        return 1
    fi
}

service_is_active() {
    if [ "$INIT_SYS" = "systemd" ]; then
        systemctl is-active --quiet xray
    elif [ "$INIT_SYS" = "openrc" ]; then
        rc-service xray status >/dev/null 2>&1
    else
        return 1
    fi
}

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

# 校验端口号是否合法 (1-65535)
is_valid_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# 校验标准 UUID 格式
is_valid_uuid() {
    printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

# 校验 ShortId 格式 (2-16 位偶数长度十六进制字符)
is_valid_shortid() {
    printf '%s' "$1" | grep -Eq '^([0-9a-fA-F]{2}){1,8}$'
}

# 检查本机端口是否已被占用
is_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tuln 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}$"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
    else
        return 1
    fi
}

# 判断端口是否在空格分隔的排除列表中
port_in_list() {
    local target="$1"
    local list="$2"
    case " $list " in
        *" $target "*) return 0 ;;
        *) return 1 ;;
    esac
}

# 生成指定范围内未占用的随机端口 (第3参数支持空格分隔的多个排除端口)
get_free_random_port() {
    local min="$1"
    local max="${2:-65535}"
    local exclude_list="${3:-}"
    local tries=0
    local candidate=""

    while [ "$tries" -lt 50 ]; do
        if command -v shuf >/dev/null 2>&1; then
            candidate=$(shuf -i "${min}-${max}" -n 1)
        else
            candidate=$(awk -v min="$min" -v max="$max" -v seed="$((tries + $$))" 'BEGIN{srand(seed); print int(min+rand()*(max-min+1))}')
        fi

        if ! port_in_list "$candidate" "$exclude_list" && ! is_port_in_use "$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
        tries=$((tries + 1))
    done

    printf '%s' "$candidate"
}

# 1. 多系统依赖检查与安装
install_dependencies() {
    cecho "${GREEN}正在检查并安装系统依赖 (包管理器: ${PKG_MGR}, 服务管理: ${INIT_SYS})...${PLAIN}"
    case "$PKG_MGR" in
        apt)
            apt-get update -y || cecho "${YELLOW}apt update 出现警告，尝试继续安装依赖...${PLAIN}"
            apt-get install -y curl wget unzip jq openssl ca-certificates qrencode
            ;;
        dnf|yum)
            "$PKG_MGR" install -y curl wget unzip jq openssl ca-certificates
            if ! command -v qrencode >/dev/null 2>&1; then
                "$PKG_MGR" install -y epel-release >/dev/null 2>&1 || true
                "$PKG_MGR" install -y qrencode >/dev/null 2>&1 || true
            fi
            ;;
        pacman)
            pacman -Sy --noconfirm --needed curl wget unzip jq openssl ca-certificates qrencode
            ;;
        zypper)
            zypper --non-interactive refresh || true
            zypper --non-interactive install curl wget unzip jq openssl ca-certificates qrencode || true
            ;;
        apk)
            apk update || true
            apk add --no-cache curl wget unzip jq openssl ca-certificates coreutils
            apk add --no-cache libqrencode-tools >/dev/null 2>&1 || apk add --no-cache qrencode >/dev/null 2>&1 || true
            ;;
        *)
            cecho "${YELLOW}无法识别包管理器，请确保已手动安装: curl, wget, unzip, jq, openssl, qrencode${PLAIN}"
            ;;
    esac
}

# OpenRC (如 Alpine) 专用 Xray 安装逻辑
install_xray_openrc() {
    local arch_raw xray_arch tmp_dir zip_url
    arch_raw=$(uname -m)
    case "$arch_raw" in
        x86_64|amd64) xray_arch="64" ;;
        aarch64|arm64) xray_arch="arm64-v8a" ;;
        armv7l|armv7) xray_arch="arm32-v7a" ;;
        i386|i686) xray_arch="32" ;;
        *)
            cecho "${RED}错误：暂不支持的 CPU 架构 (${arch_raw})。${PLAIN}"
            return 1
            ;;
    esac

    tmp_dir=$(mktemp -d)
    zip_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${xray_arch}.zip"

    cecho "${GREEN}正在为 OpenRC 系统下载 Xray (${xray_arch})...${PLAIN}"
    if ! curl -fsSL "$zip_url" -o "${tmp_dir}/xray.zip"; then
        rm -rf "$tmp_dir"
        cecho "${RED}错误：下载 Xray 失败，请检查网络连接或 GitHub 访问情况。${PLAIN}"
        return 1
    fi

    unzip -qo "${tmp_dir}/xray.zip" -d "$tmp_dir"
    mkdir -p /usr/local/bin "$XRAY_SHARE_DIR" /usr/local/etc/xray
    cp "${tmp_dir}/xray" "$XRAY_BIN"
    chmod 755 "$XRAY_BIN"
    [ -f "${tmp_dir}/geoip.dat" ] && cp "${tmp_dir}/geoip.dat" "${XRAY_SHARE_DIR}/geoip.dat" && chmod 644 "${XRAY_SHARE_DIR}/geoip.dat"
    [ -f "${tmp_dir}/geosite.dat" ] && cp "${tmp_dir}/geosite.dat" "${XRAY_SHARE_DIR}/geosite.dat" && chmod 644 "${XRAY_SHARE_DIR}/geosite.dat"
    rm -rf "$tmp_dir"

    cat > /etc/init.d/xray <<'EOF'
#!/sbin/openrc-run

name="xray"
description="Xray Service"
command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
export XRAY_LOCATION_ASSET="/usr/local/share/xray"

depend() {
    need net
    after firewall
}
EOF
    chmod 755 /etc/init.d/xray
}

# 2. 安装/更新 Xray (自动区分 systemd 与 OpenRC)
install_xray() {
    cecho "${GREEN}正在安装/更新 Xray...${PLAIN}"
    if [ "$INIT_SYS" = "systemd" ]; then
        bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    elif [ "$INIT_SYS" = "openrc" ]; then
        install_xray_openrc || return 1
    else
        cecho "${RED}错误：当前系统既无 systemd 也无 OpenRC（例如极简 Docker 容器），无法自动安装系统服务。${PLAIN}"
        return 1
    fi

    if [ ! -f "$XRAY_BIN" ]; then
        cecho "${RED}错误：Xray 安装失败，未找到 $XRAY_BIN 文件。${PLAIN}"
        cecho "${RED}请检查网络连接或 Github 访问情况。${PLAIN}"
        return 1
    fi
    cecho "${GREEN}Xray 安装检查通过。${PLAIN}"
}

# 卸载 Xray
uninstall_xray() {
    cecho "${YELLOW}正在卸载 Xray...${PLAIN}"
    if [ "$INIT_SYS" = "systemd" ]; then
        bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove
    elif [ "$INIT_SYS" = "openrc" ]; then
        rc-service xray stop >/dev/null 2>&1 || true
        rc-update del xray default >/dev/null 2>&1 || true
        rm -f /etc/init.d/xray "$XRAY_BIN"
        rm -rf "$XRAY_SHARE_DIR"
    fi
    rm -rf /usr/local/etc/xray
    cecho "${GREEN}Xray 卸载完成。${PLAIN}"
}

# 获取本机 IP (优先 IPv4，无 IPv4 时回落 IPv6)
get_ip() {
    local ip
    ip=$(curl -s4m8 ip.sb)
    if [ -z "$ip" ]; then
        ip=$(curl -s4m8 ifconfig.me)
    fi
    if [ -z "$ip" ]; then
        ip=$(curl -s6m8 ip.sb)
    fi
    printf '%s' "$ip"
}

# 纯本地 URL 编码 (防止中文或空格节点名破坏分享链接)
url_encode() {
    jq -rn --arg v "$1" '$v | @uri'
}

# POSIX 单引号安全转义
escape_sq() {
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

# 纯本地渲染终端二维码 (不联网)
render_qr() {
    local title="$1"
    local content="$2"
    if command -v qrencode >/dev/null 2>&1; then
        if [ "${#content}" -gt 1200 ]; then
            cecho "${YELLOW}提示：${title} 链接过长 (${#content} 字符，如 ML-KEM-768)，已跳过终端二维码渲染，请直接复制上方链接导入。${PLAIN}"
            return 0
        fi
        cecho "${CYAN}${title} (本地生成):${PLAIN}"
        qrencode -t ANSIUTF8 -m 2 "$content"
    else
        cecho "${YELLOW}提示：未检测到 qrencode，跳过终端二维码渲染（请手动安装 qrencode / libqrencode-tools 后重试）。${PLAIN}"
    fi
}

# 生成 SS 密码 (智能匹配算法要求)
generate_ss_password() {
    local method="$1"
    case "$method" in
        "2022-blake3-aes-128-gcm") openssl rand -base64 16 ;;
        *2022-blake3*) openssl rand -base64 32 ;;
        *) openssl rand -base64 24 ;;
    esac
}

# 生成 VLESS Encryption 密钥对 (通过全局变量 VE_DECRYPTION / VE_ENCRYPTION 返回)
generate_vless_enc_keys() {
    local auth_choice="$1"
    local vlessenc_out dec1 enc1 dec2 enc2 mlkem_seed mlkem_client
    vlessenc_out=$("$XRAY_BIN" vlessenc 2>/dev/null)
    if [ -z "$vlessenc_out" ]; then
        cecho "${RED}错误：无法运行 xray vlessenc，请先更新 Xray 内核至 v25.9.5 或更高版本！${PLAIN}"
        return 1
    fi

    dec1=$(printf '%s\n' "$vlessenc_out" | grep '"decryption":' | sed -n '1p' | cut -d'"' -f4)
    enc1=$(printf '%s\n' "$vlessenc_out" | grep '"encryption":' | sed -n '1p' | cut -d'"' -f4)
    dec2=$(printf '%s\n' "$vlessenc_out" | grep '"decryption":' | sed -n '2p' | cut -d'"' -f4)
    enc2=$(printf '%s\n' "$vlessenc_out" | grep '"encryption":' | sed -n '2p' | cut -d'"' -f4)

    if [ -z "$dec1" ] || [ -z "$enc1" ] || [ -z "$dec2" ] || [ -z "$enc2" ]; then
        cecho "${RED}错误：解析 xray vlessenc 输出失败！${PLAIN}"
        return 1
    fi

    case "$auth_choice" in
        2)
            VE_DECRYPTION="$dec2"
            VE_ENCRYPTION="$enc2"
            ;;
        3)
            mlkem_seed=$(printf '%s' "$dec2" | cut -d. -f4)
            mlkem_client=$(printf '%s' "$enc2" | cut -d. -f4)
            VE_DECRYPTION="${dec1}.${mlkem_seed}"
            VE_ENCRYPTION="${enc1}.${mlkem_client}"
            ;;
        *)
            VE_DECRYPTION="$dec1"
            VE_ENCRYPTION="$enc1"
            ;;
    esac
    return 0
}

# 从 X25519 类型的 decryption 反推客户端 encryption (用于未保存 node_info.env 时的回落)
derive_vless_enc_client() {
    local dec="$1"
    local prefix mode key pub
    prefix=$(printf '%s' "$dec" | cut -d. -f1)
    mode=$(printf '%s' "$dec" | cut -d. -f2)
    key=$(printf '%s' "$dec" | cut -d. -f4)
    # 仅对标准 43/44 字符 X25519 私钥尝试推导
    if [ "${#key}" -ge 40 ] && [ "${#key}" -le 50 ] && [ -x "$XRAY_BIN" ]; then
        pub=$("$XRAY_BIN" x25519 -i "$key" 2>/dev/null | grep -Ei "^(Public|Password)" | head -n 1 | cut -d: -f2 | tr -d ' \r\n')
        if [ -n "$pub" ]; then
            printf '%s.%s.0rtt.%s' "$prefix" "$mode" "$pub"
            return 0
        fi
    fi
    return 1
}

# 保存节点元数据到本地 (权限 600，保留未传入的字段)
save_node_metadata() {
    local new_name="${1:-}"
    local new_ip="${2:-}"
    local new_ve_enc="${3:-__KEEP__}"

    local old_name="" old_ip="" old_ve_enc=""
    if [ -f "$INFO_FILE" ]; then
        # shellcheck disable=SC1090
        . "$INFO_FILE"
        old_name="$NODE_NAME"
        old_ip="$SERVER_IP"
        old_ve_enc="$VLESS_ENC_CLIENT"
    fi

    [ -z "$new_name" ] && new_name="$old_name"
    [ -z "$new_ip" ] && new_ip="$old_ip"
    if [ "$new_ve_enc" = "__KEEP__" ]; then
        new_ve_enc="$old_ve_enc"
    fi

    mkdir -p "$(dirname "$INFO_FILE")"
    {
        printf "NODE_NAME='%s'\n" "$(escape_sq "$new_name")"
        printf "SERVER_IP='%s'\n" "$(escape_sq "$new_ip")"
        printf "VLESS_ENC_CLIENT='%s'\n" "$(escape_sq "$new_ve_enc")"
    } > "$INFO_FILE"
    chmod 600 "$INFO_FILE"
}

# 原子校验、应用临时配置文件并重启 Xray
apply_and_restart_config() {
    local tmp_cfg="$1"
    local test_cfg="${tmp_cfg}.json"
    mv "$tmp_cfg" "$test_cfg"

    cecho "${GREEN}正在校验新配置文件...${PLAIN}"
    if ! XRAY_LOCATION_ASSET="$XRAY_SHARE_DIR" "$XRAY_BIN" run -test -config "$test_cfg"; then
        cecho "${RED}错误：新配置未通过 Xray 校验，已自动放弃修改，原配置保持不变！${PLAIN}"
        rm -f "$test_cfg"
        return 1
    fi

    mv "$test_cfg" "$CONFIG_FILE"
    secure_config_permissions

    service_enable_and_restart || return 1
    sleep 1

    if ! service_is_active; then
        cecho "${RED}错误：Xray 服务重启失败！${PLAIN}"
        if [ "$INIT_SYS" = "systemd" ]; then
            cecho "${YELLOW}请运行 journalctl -u xray -n 20 查看日志。${PLAIN}"
        else
            cecho "${YELLOW}请运行 rc-service xray status 查看服务状态。${PLAIN}"
        fi
        return 1
    fi

    cecho "${GREEN}配置已生效并成功重启 Xray！${PLAIN}"
    return 0
}

# 查看当前已配置的节点信息、纯本地分享链接与二维码
show_node_info() {
    if [ ! -f "$CONFIG_FILE" ]; then
        cecho "${RED}未找到配置文件 ($CONFIG_FILE)，请先安装配置 Xray。${PLAIN}"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v qrencode >/dev/null 2>&1; then
        cecho "${YELLOW}检测到缺少必要工具，正在尝试自动安装...${PLAIN}"
        install_dependencies
    fi

    if ! command -v jq >/dev/null 2>&1; then
        cecho "${RED}错误：缺少 jq，无法解析配置文件。${PLAIN}"
        return 1
    fi

    local custom_node_name="" server_ip="" saved_ve_client=""
    if [ -f "$INFO_FILE" ]; then
        # shellcheck disable=SC1090
        . "$INFO_FILE"
        custom_node_name="$NODE_NAME"
        server_ip="$SERVER_IP"
        saved_ve_client="$VLESS_ENC_CLIENT"
    fi

    [ -z "$custom_node_name" ] && custom_node_name=$(uname -n)
    if [ -z "$server_ip" ]; then
        server_ip=$(get_ip)
        [ -n "$server_ip" ] && save_node_metadata "$custom_node_name" "$server_ip"
    fi

    local link_ip="$server_ip"
    case "$server_ip" in
        *:*) link_ip="[${server_ip}]" ;;
    esac

    local service_status="${RED}未运行${PLAIN}"
    if service_is_active; then
        service_status="${GREEN}运行中${PLAIN}"
    fi
    local default_outbound
    default_outbound=$(jq -r '.routing.rules[-1].outboundTag // "未知"' "$CONFIG_FILE")

    local reality_json ss_json ve_json
    reality_json=$(jq -c '.inbounds[] | select(.protocol == "vless" and .streamSettings.security == "reality")' "$CONFIG_FILE" | head -n 1)
    ss_json=$(jq -c '.inbounds[] | select(.protocol == "shadowsocks")' "$CONFIG_FILE" | head -n 1)
    ve_json=$(jq -c '.inbounds[] | select(.protocol == "vless" and (.settings.decryption // "none") != "none")' "$CONFIG_FILE" | head -n 1)

    if [ -z "$reality_json" ] && [ -z "$ss_json" ] && [ -z "$ve_json" ]; then
        cecho "${RED}当前配置文件中未检测到 Reality、Shadowsocks 或 VLESS Encryption 节点。${PLAIN}"
        return 1
    fi

    local proto_count=0
    [ -n "$reality_json" ] && proto_count=$((proto_count + 1))
    [ -n "$ss_json" ] && proto_count=$((proto_count + 1))
    [ -n "$ve_json" ] && proto_count=$((proto_count + 1))

    cecho ""
    cecho "${GREEN}================ 当前节点信息 ================${PLAIN}"
    cecho "运行状态: ${service_status}"
    cecho "服务器 IP: ${CYAN}${server_ip}${PLAIN}"
    cecho "默认出口: ${CYAN}${default_outbound}${PLAIN}"

    # 展示 Reality 节点与本地二维码
    if [ -n "$reality_json" ]; then
        local reality_port reality_uuid reality_flow reality_sni reality_private_key reality_shortid
        reality_port=$(printf '%s' "$reality_json" | jq -r '.port // empty')
        reality_uuid=$(printf '%s' "$reality_json" | jq -r '.settings.clients[0].id // empty')
        reality_flow=$(printf '%s' "$reality_json" | jq -r '.settings.clients[0].flow // "xtls-rprx-vision"')
        reality_sni=$(printf '%s' "$reality_json" | jq -r '.streamSettings.realitySettings.serverNames[0] // empty')
        reality_private_key=$(printf '%s' "$reality_json" | jq -r '.streamSettings.realitySettings.privateKey // empty')
        reality_shortid=$(printf '%s' "$reality_json" | jq -r '.streamSettings.realitySettings.shortIds[0] // empty')

        local dokodemo_json reality_dest_display reality_inner_display d_addr d_port
        dokodemo_json=$(jq -c '.inbounds[] | select(.protocol == "dokodemo-door")' "$CONFIG_FILE" | head -n 1)
        reality_inner_display=""
        if [ -n "$dokodemo_json" ]; then
            d_addr=$(printf '%s' "$dokodemo_json" | jq -r '.settings.address // empty')
            d_port=$(printf '%s' "$dokodemo_json" | jq -r '.settings.port // empty')
            if [ "$d_addr" = "127.0.0.1" ]; then
                reality_dest_display=$(printf '%s' "$reality_json" | jq -r '.streamSettings.realitySettings.dest // empty')
            else
                reality_dest_display="${d_addr}:${d_port}"
                reality_inner_display=$(printf '%s' "$dokodemo_json" | jq -r '.port // empty')
            fi
        else
            reality_dest_display=$(printf '%s' "$reality_json" | jq -r '.streamSettings.realitySettings.dest // empty')
        fi

        local reality_public_key=""
        if [ -n "$reality_private_key" ] && [ -x "$XRAY_BIN" ]; then
            reality_public_key=$("$XRAY_BIN" x25519 -i "$reality_private_key" 2>/dev/null | grep -Ei "^(Public|Password)" | cut -d: -f2 | tr -d ' \r\n')
        fi

        local alias="$custom_node_name"
        [ "$proto_count" -gt 1 ] && alias="${custom_node_name}-Reality"
        local encoded_alias reality_link
        encoded_alias=$(url_encode "$alias")
        reality_link="vless://${reality_uuid}@${link_ip}:${reality_port}?encryption=none&flow=${reality_flow}&security=reality&sni=${reality_sni}&fp=chrome&pbk=${reality_public_key}&sid=${reality_shortid}&type=tcp&headerType=none#${encoded_alias}"

        cecho "\n${YELLOW}--- [Reality 节点] ---${PLAIN}"
        cecho "节点备注: ${alias}"
        cecho "外网端口 (Port): ${reality_port}"
        [ -n "$reality_inner_display" ] && cecho "内网回落端口: 127.0.0.1:${reality_inner_display}"
        cecho "UUID: ${reality_uuid}"
        cecho "流控 (Flow): ${reality_flow}"
        cecho "真实伪装目标: ${reality_dest_display}"
        cecho "SNI: ${reality_sni}"
        cecho "公钥 (PBK): ${reality_public_key}"
        cecho "ShortId: ${reality_shortid}"
        cecho "${GREEN}VLESS 分享链接 (本地生成):${PLAIN}"
        cecho "${reality_link}"
        cecho ""
        render_qr "Reality 二维码" "$reality_link"
    fi

    # 展示 Shadowsocks 节点与本地二维码
    if [ -n "$ss_json" ]; then
        local ss_port ss_method ss_password ss_alias encoded_ss_alias b64_user_pass ss_link
        ss_port=$(printf '%s' "$ss_json" | jq -r '.port // empty')
        ss_method=$(printf '%s' "$ss_json" | jq -r '.settings.method // empty')
        ss_password=$(printf '%s' "$ss_json" | jq -r '.settings.password // empty')

        ss_alias="$custom_node_name"
        [ "$proto_count" -gt 1 ] && ss_alias="${custom_node_name}-SS"
        encoded_ss_alias=$(url_encode "$ss_alias")
        b64_user_pass=$(printf '%s:%s' "$ss_method" "$ss_password" | base64 | tr -d '\r\n')
        ss_link="ss://${b64_user_pass}@${link_ip}:${ss_port}#${encoded_ss_alias}"

        cecho "\n${YELLOW}--- [Shadowsocks 节点] ---${PLAIN}"
        cecho "节点备注: ${ss_alias}"
        cecho "端口 (Port): ${ss_port}"
        cecho "加密 (Method): ${ss_method}"
        cecho "密码 (Password): ${ss_password}"
        cecho "${GREEN}SS 分享链接 (本地生成):${PLAIN}"
        cecho "${ss_link}"
        cecho ""
        render_qr "Shadowsocks 二维码" "$ss_link"
    fi

    # 展示 VLESS Encryption 节点与本地二维码
    if [ -n "$ve_json" ]; then
        local ve_port ve_uuid ve_flow ve_dec ve_net ve_enc_client ve_alias encoded_ve_alias ve_link flow_param
        ve_port=$(printf '%s' "$ve_json" | jq -r '.port // empty')
        ve_uuid=$(printf '%s' "$ve_json" | jq -r '.settings.clients[0].id // empty')
        ve_flow=$(printf '%s' "$ve_json" | jq -r '.settings.clients[0].flow // empty')
        ve_dec=$(printf '%s' "$ve_json" | jq -r '.settings.decryption // empty')
        ve_net=$(printf '%s' "$ve_json" | jq -r '.streamSettings.network // "raw"')

        ve_enc_client="$saved_ve_client"
        if [ -z "$ve_enc_client" ]; then
            ve_enc_client=$(derive_vless_enc_client "$ve_dec" || true)
        fi

        ve_alias="$custom_node_name"
        [ "$proto_count" -gt 1 ] && ve_alias="${custom_node_name}-VLESS-Enc"
        encoded_ve_alias=$(url_encode "$ve_alias")

        cecho "\n${YELLOW}--- [VLESS Encryption 节点] ---${PLAIN}"
        cecho "节点备注: ${ve_alias}"
        cecho "端口 (Port): ${ve_port}"
        cecho "UUID: ${ve_uuid}"
        cecho "流控 (Flow): ${ve_flow:-无}"
        cecho "传输协议 (Network): ${ve_net}"
        cecho "服务端 Decryption: ${ve_dec}"
        if [ -n "$ve_enc_client" ]; then
            cecho "客户端 Encryption: ${ve_enc_client}"
            flow_param=""
            [ -n "$ve_flow" ] && flow_param="&flow=${ve_flow}"
            ve_link="vless://${ve_uuid}@${link_ip}:${ve_port}?encryption=$(url_encode "$ve_enc_client")${flow_param}&security=none&type=${ve_net}#${encoded_ve_alias}"
            cecho "${GREEN}VLESS Encryption 分享链接 (本地生成):${PLAIN}"
            cecho "${ve_link}"
            cecho ""
            render_qr "VLESS Encryption 二维码" "$ve_link"
        else
            cecho "${YELLOW}提示：未能从 node_info.env 读取客户端 Encryption（若为 ML-KEM-768 且经迁移而来，请手动对照原客户端 encryption 配置，或通过修改菜单重新生成密钥对）。${PLAIN}"
        fi
    fi

    cecho "${GREEN}==============================================${PLAIN}"
}

# 在临时配置副本中局部修改 Reality 节点
edit_reality_in_tmp() {
    local tmp_cfg="$1"
    local reality_json dokodemo_json
    reality_json=$(jq -c '.inbounds[] | select(.protocol == "vless" and .streamSettings.security == "reality")' "$tmp_cfg" | head -n 1)
    if [ -z "$reality_json" ]; then
        cecho "${RED}错误：当前配置中未找到 Reality 节点。${PLAIN}"
        return 1
    fi

    local cur_port cur_uuid cur_sni cur_pk cur_sid cur_dest cur_inner_port
    cur_port=$(printf '%s' "$reality_json" | jq -r '.port')
    cur_uuid=$(printf '%s' "$reality_json" | jq -r '.settings.clients[0].id')
    cur_sni=$(printf '%s' "$reality_json" | jq -r '.streamSettings.realitySettings.serverNames[0]')
    cur_pk=$(printf '%s' "$reality_json" | jq -r '.streamSettings.realitySettings.privateKey')
    cur_sid=$(printf '%s' "$reality_json" | jq -r '.streamSettings.realitySettings.shortIds[0]')

    dokodemo_json=$(jq -c '.inbounds[] | select(.protocol == "dokodemo-door" and .settings.address != "127.0.0.1")' "$tmp_cfg" | head -n 1)
    if [ -n "$dokodemo_json" ]; then
        cur_dest="$(printf '%s' "$dokodemo_json" | jq -r '.settings.address'):$(printf '%s' "$dokodemo_json" | jq -r '.settings.port')"
        cur_inner_port=$(printf '%s' "$dokodemo_json" | jq -r '.port')
    else
        cur_dest=$(printf '%s' "$reality_json" | jq -r '.streamSettings.realitySettings.dest')
        cur_inner_port=""
    fi

    cecho "\n${YELLOW}--- 修改 Reality 节点 (直接回车保留当前值) ---${PLAIN}"

    printf "外网端口 [当前: %s]: " "$cur_port"
    read -r new_port
    [ -z "$new_port" ] && new_port="$cur_port"
    if ! is_valid_port "$new_port"; then
        cecho "${RED}错误：外网端口号 (${new_port}) 无效，必须为 1-65535。${PLAIN}"
        return 1
    fi

    local new_inner_port="$cur_inner_port"
    if [ -n "$dokodemo_json" ]; then
        printf "内网回落端口 [当前: %s] (回车不变，输入 auto 随机): " "$cur_inner_port"
        read -r inner_input
        if [ "$inner_input" = "auto" ]; then
            new_inner_port=$(get_free_random_port 20000 39999 "$new_port")
        elif [ -n "$inner_input" ]; then
            new_inner_port="$inner_input"
        fi
        if ! is_valid_port "$new_inner_port"; then
            cecho "${RED}错误：内网回落端口 (${new_inner_port}) 无效，必须为 1-65535。${PLAIN}"
            return 1
        fi
        if [ "$new_inner_port" = "$new_port" ]; then
            cecho "${RED}错误：内网回落端口不能与外网端口 (${new_port}) 冲突！${PLAIN}"
            return 1
        fi
    fi

    printf "真实伪装目标 [当前: %s]: " "$cur_dest"
    read -r new_dest
    [ -z "$new_dest" ] && new_dest="$cur_dest"
    case "$new_dest" in
        *:*)
            new_dest_host=$(printf '%s' "$new_dest" | cut -d: -f1)
            new_dest_port=$(printf '%s' "$new_dest" | cut -d: -f2)
            ;;
        *)
            new_dest_host="$new_dest"
            new_dest_port="443"
            ;;
    esac
    if ! is_valid_port "$new_dest_port"; then
        cecho "${RED}错误：伪装目标端口 (${new_dest_port}) 无效！${PLAIN}"
        return 1
    fi

    local sni_default="$cur_sni"
    [ "$new_dest" != "$cur_dest" ] && sni_default="$new_dest_host"
    printf "SNI 域名 serverName [默认: %s]: " "$sni_default"
    read -r new_sni
    [ -z "$new_sni" ] && new_sni="$sni_default"

    local new_uuid="$cur_uuid"
    printf "UUID [当前: %s] (回车不变，输入 auto 随机): " "$cur_uuid"
    read -r uuid_input
    if [ "$uuid_input" = "auto" ]; then
        new_uuid=$("$XRAY_BIN" uuid)
    elif [ -n "$uuid_input" ]; then
        if ! is_valid_uuid "$uuid_input"; then
            cecho "${RED}错误：UUID 格式无效！${PLAIN}"
            return 1
        fi
        new_uuid="$uuid_input"
    fi

    local new_sid="$cur_sid"
    printf "ShortId [当前: %s] (回车不变，输入 auto 随机): " "$cur_sid"
    read -r sid_input
    if [ "$sid_input" = "auto" ]; then
        new_sid=$(openssl rand -hex 8)
    elif [ -n "$sid_input" ]; then
        if ! is_valid_shortid "$sid_input"; then
            cecho "${RED}错误：ShortId 必须为 2-16 位偶数长度的十六进制字符 (0-9, a-f)！${PLAIN}"
            return 1
        fi
        new_sid="$sid_input"
    fi

    local new_pk="$cur_pk"
    printf "是否重新生成 X25519 密钥对? (y/n, 默认 n): "
    read -r regen_key
    if [ "$regen_key" = "y" ] || [ "$regen_key" = "Y" ]; then
        local x25519_out
        x25519_out=$("$XRAY_BIN" x25519)
        new_pk=$(printf '%s\n' "$x25519_out" | grep -i "^Private" | cut -d: -f2 | tr -d ' \r\n')
        if [ -z "$new_pk" ]; then
            cecho "${RED}错误：重新生成 X25519 密钥失败！${PLAIN}"
            return 1
        fi
        cecho "${GREEN}已生成新的 X25519 密钥对。${PLAIN}"
    fi

    local next_cfg="${tmp_cfg}.next"
    if [ -n "$dokodemo_json" ]; then
        jq --argjson port "$new_port" \
           --argjson iport "$new_inner_port" \
           --arg dhost "$new_dest_host" \
           --argjson dport "$new_dest_port" \
           --arg sni "$new_sni" \
           --arg uuid "$new_uuid" \
           --arg pk "$new_pk" \
           --arg sid "$new_sid" \
           '(.inbounds[] | select(.protocol == "vless" and .streamSettings.security == "reality")) |= (
                .port = $port |
                .settings.clients[0].id = $uuid |
                .streamSettings.realitySettings.dest = ("127.0.0.1:" + ($iport | tostring)) |
                .streamSettings.realitySettings.serverNames = [$sni] |
                .streamSettings.realitySettings.privateKey = $pk |
                .streamSettings.realitySettings.shortIds = [$sid]
            )
            | (.inbounds[] | select(.protocol == "dokodemo-door" and .settings.address != "127.0.0.1")) |= (
                .port = $iport |
                .settings.address = $dhost |
                .settings.port = $dport
            )
            | (.routing.rules[] | select(((.inboundTag // []) | any(. == "dokodemo-in")) and has("domain")) | .domain) = [$sni]' \
            "$tmp_cfg" > "$next_cfg" || { rm -f "$next_cfg"; return 1; }
    else
        jq --argjson port "$new_port" \
           --arg dest "${new_dest_host}:${new_dest_port}" \
           --arg sni "$new_sni" \
           --arg uuid "$new_uuid" \
           --arg pk "$new_pk" \
           --arg sid "$new_sid" \
           '(.inbounds[] | select(.protocol == "vless" and .streamSettings.security == "reality")) |= (
                .port = $port |
                .settings.clients[0].id = $uuid |
                .streamSettings.realitySettings.dest = $dest |
                .streamSettings.realitySettings.serverNames = [$sni] |
                .streamSettings.realitySettings.privateKey = $pk |
                .streamSettings.realitySettings.shortIds = [$sid]
            )' \
            "$tmp_cfg" > "$next_cfg" || { rm -f "$next_cfg"; return 1; }
    fi

    mv "$next_cfg" "$tmp_cfg"
    return 0
}

# 在临时配置副本中局部修改 Shadowsocks 节点
edit_ss_in_tmp() {
    local tmp_cfg="$1"
    local ss_json
    ss_json=$(jq -c '.inbounds[] | select(.protocol == "shadowsocks")' "$tmp_cfg" | head -n 1)
    if [ -z "$ss_json" ]; then
        cecho "${RED}错误：当前配置中未找到 Shadowsocks 节点。${PLAIN}"
        return 1
    fi

    local cur_port cur_method cur_pass
    cur_port=$(printf '%s' "$ss_json" | jq -r '.port')
    cur_method=$(printf '%s' "$ss_json" | jq -r '.settings.method')
    cur_pass=$(printf '%s' "$ss_json" | jq -r '.settings.password')

    cecho "\n${YELLOW}--- 修改 Shadowsocks 节点 (直接回车保留当前值) ---${PLAIN}"

    printf "SS 端口 [当前: %s]: " "$cur_port"
    read -r new_port
    [ -z "$new_port" ] && new_port="$cur_port"
    if ! is_valid_port "$new_port"; then
        cecho "${RED}错误：端口号 (${new_port}) 无效，必须为 1-65535。${PLAIN}"
        return 1
    fi

    cecho "当前加密方式: ${CYAN}${cur_method}${PLAIN}"
    cecho "可选加密方式 (直接回车保持不变):"
    cecho "1. 2022-blake3-aes-128-gcm"
    cecho "2. 2022-blake3-aes-256-gcm"
    cecho "3. 2022-blake3-chacha20-poly1305"
    cecho "4. aes-128-gcm"
    cecho "5. aes-256-gcm"
    cecho "6. chacha20-poly1305"
    cecho "7. xchacha20-poly1305"
    printf "请选择 [1-7] (回车不变): "
    read -r method_choice

    local new_method="$cur_method"
    case "$method_choice" in
        1) new_method="2022-blake3-aes-128-gcm" ;;
        2) new_method="2022-blake3-aes-256-gcm" ;;
        3) new_method="2022-blake3-chacha20-poly1305" ;;
        4) new_method="aes-128-gcm" ;;
        5) new_method="aes-256-gcm" ;;
        6) new_method="chacha20-poly1305" ;;
        7) new_method="xchacha20-poly1305" ;;
        '') new_method="$cur_method" ;;
        *)
            cecho "${YELLOW}输入无效，保持原加密方式: ${cur_method}${PLAIN}"
            new_method="$cur_method"
            ;;
    esac

    local new_pass="$cur_pass"
    if [ "$new_method" != "$cur_method" ]; then
        cecho "${YELLOW}提示：加密方式已变更，留空将自动生成匹配 ${new_method} 的新密码。${PLAIN}"
        printf "请输入新 SS 密码 (留空自动生成): "
        read -r pass_input
        if [ -z "$pass_input" ]; then
            new_pass=$(generate_ss_password "$new_method")
        else
            new_pass="$pass_input"
        fi
    else
        printf "SS 密码 (回车保持不变，输入 auto 随机重置): "
        read -r pass_input
        if [ "$pass_input" = "auto" ]; then
            new_pass=$(generate_ss_password "$new_method")
        elif [ -n "$pass_input" ]; then
            new_pass="$pass_input"
        fi
    fi

    local next_cfg="${tmp_cfg}.next"
    jq --argjson port "$new_port" \
       --arg method "$new_method" \
       --arg pass "$new_pass" \
       '(.inbounds[] | select(.protocol == "shadowsocks")) |= (
            .port = $port |
            .settings.method = $method |
            .settings.password = $pass
        )' \
        "$tmp_cfg" > "$next_cfg" || { rm -f "$next_cfg"; return 1; }

    mv "$next_cfg" "$tmp_cfg"
    return 0
}

# 在临时配置副本中局部修改 VLESS Encryption 节点
edit_vless_enc_in_tmp() {
    local tmp_cfg="$1"
    local ve_json
    ve_json=$(jq -c '.inbounds[] | select(.protocol == "vless" and (.settings.decryption // "none") != "none")' "$tmp_cfg" | head -n 1)
    if [ -z "$ve_json" ]; then
        cecho "${RED}错误：当前配置中未找到 VLESS Encryption 节点。${PLAIN}"
        return 1
    fi

    local cur_port cur_uuid cur_flow cur_dec
    cur_port=$(printf '%s' "$ve_json" | jq -r '.port')
    cur_uuid=$(printf '%s' "$ve_json" | jq -r '.settings.clients[0].id')
    cur_flow=$(printf '%s' "$ve_json" | jq -r '.settings.clients[0].flow // ""')
    cur_dec=$(printf '%s' "$ve_json" | jq -r '.settings.decryption')

    cecho "\n${YELLOW}--- 修改 VLESS Encryption 节点 (直接回车保留当前值) ---${PLAIN}"

    printf "端口 [当前: %s]: " "$cur_port"
    read -r new_port
    [ -z "$new_port" ] && new_port="$cur_port"
    if ! is_valid_port "$new_port"; then
        cecho "${RED}错误：端口号 (${new_port}) 无效，必须为 1-65535。${PLAIN}"
        return 1
    fi

    local new_uuid="$cur_uuid"
    printf "UUID [当前: %s] (回车不变，输入 auto 随机): " "$cur_uuid"
    read -r uuid_input
    if [ "$uuid_input" = "auto" ]; then
        new_uuid=$("$XRAY_BIN" uuid)
    elif [ -n "$uuid_input" ]; then
        if ! is_valid_uuid "$uuid_input"; then
            cecho "${RED}错误：UUID 格式无效！${PLAIN}"
            return 1
        fi
        new_uuid="$uuid_input"
    fi

    printf "流控 Flow [当前: %s] (回车不变，输入 none 清空，或手动输入如 xtls-rprx-vision): " "${cur_flow:-无}"
    read -r flow_input
    local new_flow="$cur_flow"
    if [ "$flow_input" = "none" ]; then
        new_flow=""
    elif [ -n "$flow_input" ]; then
        new_flow="$flow_input"
    fi

    local new_dec="$cur_dec"
    NEW_VE_CLIENT_ENC="__KEEP__"
    printf "是否重新生成 VLESS Encryption 密钥对? (y/n, 默认 n): "
    read -r regen_ve
    if [ "$regen_ve" = "y" ] || [ "$regen_ve" = "Y" ]; then
        cecho "请选择认证方式:"
        cecho "1. X25519 (默认推荐，链接极短、支持二维码)"
        cecho "2. ML-KEM-768 (全链路后量子，字符串极长)"
        cecho "3. X25519 + ML-KEM-768 同时启用 (优点: 双重兜底防单一算法失效；缺点: 链接最长/无二维码/握手略重)"
        printf "请选择 [1-3] (默认 1): "
        read -r auth_choice
        [ -z "$auth_choice" ] && auth_choice="1"
        generate_vless_enc_keys "$auth_choice" || return 1
        new_dec="$VE_DECRYPTION"
        NEW_VE_CLIENT_ENC="$VE_ENCRYPTION"
        cecho "${GREEN}已生成新的 VLESS Encryption 密钥对。${PLAIN}"
    fi

    local next_cfg="${tmp_cfg}.next"
    jq --argjson port "$new_port" \
       --arg uuid "$new_uuid" \
       --arg flow "$new_flow" \
       --arg dec "$new_dec" \
       '(.inbounds[] | select(.protocol == "vless" and (.settings.decryption // "none") != "none")) |= (
            .port = $port |
            .settings.decryption = $dec |
            .settings.clients[0].id = $uuid |
            if $flow != "" then .settings.clients[0].flow = $flow else del(.settings.clients[0].flow) end
        )' \
        "$tmp_cfg" > "$next_cfg" || { rm -f "$next_cfg"; return 1; }

    mv "$next_cfg" "$tmp_cfg"
    return 0
}

# 修改默认出口策略或节点备注名
edit_common_settings() {
    local tmp_cfg="$1"
    local cur_out cur_name cur_ip
    cur_out=$(jq -r '.routing.rules[-1].outboundTag // "IP4_out"' "$tmp_cfg")

    cur_name=""
    cur_ip=""
    if [ -f "$INFO_FILE" ]; then
        # shellcheck disable=SC1090
        . "$INFO_FILE"
        cur_name="$NODE_NAME"
        cur_ip="$SERVER_IP"
    fi
    [ -z "$cur_name" ] && cur_name=$(uname -n)
    [ -z "$cur_ip" ] && cur_ip=$(get_ip)

    cecho "\n${YELLOW}--- 修改公共设置 (直接回车保留当前值) ---${PLAIN}"
    cecho "当前默认出口: ${CYAN}${cur_out}${PLAIN}"
    cecho "1. IPv4 出口 (IP4_out)"
    cecho "2. IPv6 出口 (IP6_out)"
    cecho "3. 系统自动适配 (direct, 适合纯 IPv6 或单栈机器)"
    printf "请选择 [1-3] (回车不变): "
    read -r out_choice

    local new_out="$cur_out"
    case "$out_choice" in
        1) new_out="IP4_out" ;;
        2) new_out="IP6_out" ;;
        3) new_out="direct" ;;
    esac

    printf "节点名称备注 [当前: %s]: " "$cur_name"
    read -r new_name
    [ -z "$new_name" ] && new_name="$cur_name"

    save_node_metadata "$new_name" "$cur_ip"

    if [ "$new_out" != "$cur_out" ]; then
        local next_cfg="${tmp_cfg}.next"
        jq --arg out "$new_out" \
           '(.routing.rules[] | select(((.inboundTag // []) | any(. == "dokodemo-in") | not) and .outboundTag != "block") | .outboundTag) = $out' \
           "$tmp_cfg" > "$next_cfg" || { rm -f "$next_cfg"; return 1; }
        mv "$next_cfg" "$tmp_cfg"
        return 0
    fi

    return 2
}

# 检查临时配置中所有入站端口是否互相冲突
check_all_port_conflicts() {
    local cfg="$1"
    local dup_port
    dup_port=$(jq -r '.inbounds[].port' "$cfg" | sort | uniq -d | head -n 1)
    if [ -n "$dup_port" ]; then
        cecho "${RED}错误：检测到入站端口冲突 (${dup_port})，已放弃修改！${PLAIN}"
        return 1
    fi
    return 0
}

# 修改节点信息入口菜单
modify_node_info() {
    if [ ! -f "$CONFIG_FILE" ]; then
        cecho "${RED}未找到配置文件 ($CONFIG_FILE)，请先执行选项 1 安装配置。${PLAIN}"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        cecho "${YELLOW}检测到缺少 jq，正在尝试自动安装...${PLAIN}"
        install_dependencies
    fi

    local has_reality="false" has_ss="false" has_ve="false"
    [ -n "$(jq -c '.inbounds[] | select(.protocol == "vless" and .streamSettings.security == "reality")' "$CONFIG_FILE" | head -n 1)" ] && has_reality="true"
    [ -n "$(jq -c '.inbounds[] | select(.protocol == "shadowsocks")' "$CONFIG_FILE" | head -n 1)" ] && has_ss="true"
    [ -n "$(jq -c '.inbounds[] | select(.protocol == "vless" and (.settings.decryption // "none") != "none")' "$CONFIG_FILE" | head -n 1)" ] && has_ve="true"

    if [ "$has_reality" = "false" ] && [ "$has_ss" = "false" ] && [ "$has_ve" = "false" ]; then
        cecho "${RED}当前配置文件中未检测到可修改的节点。${PLAIN}"
        return 1
    fi

    cecho ""
    cecho "${GREEN}--- 修改已配置的节点信息 ---${PLAIN}"
    cecho "当前已装协议: Reality=${CYAN}${has_reality}${PLAIN} | SS=${CYAN}${has_ss}${PLAIN} | VLESS-Enc=${CYAN}${has_ve}${PLAIN}"
    cecho "1. 修改 Reality 节点"
    cecho "2. 修改 Shadowsocks 节点"
    cecho "3. 修改 VLESS Encryption 节点"
    cecho "4. 修改默认出口策略 (IPv4/IPv6/自动适配) 或节点备注名"
    cecho "0. 返回主菜单"
    printf "请选择 [0-4]: "
    read -r mod_choice

    [ "$mod_choice" = "0" ] && return 2

    local tmp_cfg
    tmp_cfg=$(mktemp)
    cp "$CONFIG_FILE" "$tmp_cfg"
    NEW_VE_CLIENT_ENC="__KEEP__"

    case "$mod_choice" in
        1)
            if [ "$has_reality" = "false" ]; then
                cecho "${RED}当前未配置 Reality 节点，请使用主菜单选项 2 加装。${PLAIN}"
                rm -f "$tmp_cfg"
                return 1
            fi
            edit_reality_in_tmp "$tmp_cfg" || { rm -f "$tmp_cfg"; return 1; }
            ;;
        2)
            if [ "$has_ss" = "false" ]; then
                cecho "${RED}当前未配置 Shadowsocks 节点，请使用主菜单选项 2 加装。${PLAIN}"
                rm -f "$tmp_cfg"
                return 1
            fi
            edit_ss_in_tmp "$tmp_cfg" || { rm -f "$tmp_cfg"; return 1; }
            ;;
        3)
            if [ "$has_ve" = "false" ]; then
                cecho "${RED}当前未配置 VLESS Encryption 节点，请使用主菜单选项 2 加装。${PLAIN}"
                rm -f "$tmp_cfg"
                return 1
            fi
            edit_vless_enc_in_tmp "$tmp_cfg" || { rm -f "$tmp_cfg"; return 1; }
            ;;
        4)
            edit_common_settings "$tmp_cfg"
            local rc=$?
            if [ "$rc" -eq 2 ]; then
                rm -f "$tmp_cfg"
                cecho "${GREEN}节点备注已更新 (未改动 Xray 路由，无需重启)。${PLAIN}"
                show_node_info
                return 0
            elif [ "$rc" -ne 0 ]; then
                rm -f "$tmp_cfg"
                return 1
            fi
            ;;
        *)
            cecho "${RED}无效选择。${PLAIN}"
            rm -f "$tmp_cfg"
            return 1
            ;;
    esac

    check_all_port_conflicts "$tmp_cfg" || { rm -f "$tmp_cfg"; return 1; }

    if apply_and_restart_config "$tmp_cfg"; then
        [ "$NEW_VE_CLIENT_ENC" != "__KEEP__" ] && save_node_metadata "" "" "$NEW_VE_CLIENT_ENC"
        show_node_info
    fi
}

# === 交互式参数收集模块 (供全新安装与加装协议复用) ===

collect_reality_params() {
    local exclude_ports="$1"
    cecho "${YELLOW}--- 配置 Reality (新版防偷流量架构) ---${PLAIN}"

    printf "请输入 Reality 外网端口 (默认随机 40000-65535): "
    read -r reality_port
    if [ -z "$reality_port" ]; then
        reality_port=$(get_free_random_port 40000 65535 "$exclude_ports")
    else
        if ! is_valid_port "$reality_port"; then
            cecho "${RED}错误：Reality 外网端口 (${reality_port}) 无效！${PLAIN}"
            return 1
        fi
        if port_in_list "$reality_port" "$exclude_ports"; then
            cecho "${RED}错误：端口 (${reality_port}) 与现有节点端口冲突！${PLAIN}"
            return 1
        fi
    fi

    printf "请输入 Reality 内网回落端口 (仅监听 127.0.0.1，默认随机 20000-39999): "
    read -r reality_inner_port
    if [ -z "$reality_inner_port" ]; then
        reality_inner_port=$(get_free_random_port 20000 39999 "$exclude_ports $reality_port")
    else
        if ! is_valid_port "$reality_inner_port"; then
            cecho "${RED}错误：Reality 内网回落端口 (${reality_inner_port}) 无效！${PLAIN}"
            return 1
        fi
        if port_in_list "$reality_inner_port" "$exclude_ports $reality_port"; then
            cecho "${RED}错误：内网回落端口 (${reality_inner_port}) 与已有端口冲突！${PLAIN}"
            return 1
        fi
    fi

    printf "请输入真实伪装目标 (如 www.tesla.com:443，默认 www.tesla.com:443): "
    read -r reality_dest
    [ -z "$reality_dest" ] && reality_dest="www.tesla.com:443"
    case "$reality_dest" in
        *:*)
            reality_dest_host=$(printf '%s' "$reality_dest" | cut -d: -f1)
            reality_dest_port=$(printf '%s' "$reality_dest" | cut -d: -f2)
            ;;
        *)
            reality_dest_host="$reality_dest"
            reality_dest_port="443"
            ;;
    esac

    if ! is_valid_port "$reality_dest_port"; then
        cecho "${RED}错误：伪装目标端口 (${reality_dest_port}) 必须为 1-65535 之间的数字！${PLAIN}"
        return 1
    fi

    printf "请输入 SNI 域名 serverName (默认 %s): " "$reality_dest_host"
    read -r reality_sni
    [ -z "$reality_sni" ] && reality_sni="$reality_dest_host"

    printf "请输入 UUID (留空自动随机生成): "
    read -r reality_uuid
    if [ -z "$reality_uuid" ]; then
        reality_uuid=$("$XRAY_BIN" uuid)
    elif ! is_valid_uuid "$reality_uuid"; then
        cecho "${RED}错误：输入的 UUID 格式无效！${PLAIN}"
        return 1
    fi

    printf "请输入 ShortId (2-16位偶数十六进制字符，留空自动随机生成): "
    read -r reality_shortid
    if [ -z "$reality_shortid" ]; then
        reality_shortid=$(openssl rand -hex 8)
    elif ! is_valid_shortid "$reality_shortid"; then
        cecho "${RED}错误：ShortId 必须为 2-16 位偶数长度的十六进制字符 (0-9, a-f)！${PLAIN}"
        return 1
    fi

    cecho "${GREEN}正在生成 X25519 密钥...${PLAIN}"
    x25519_out=$("$XRAY_BIN" x25519)
    if [ -z "$x25519_out" ]; then
        cecho "${RED}错误：无法运行 Xray 生成密钥！${PLAIN}"
        return 1
    fi

    reality_private_key=$(printf '%s\n' "$x25519_out" | grep -i "^Private" | cut -d: -f2 | tr -d ' \r\n')
    reality_public_key=$(printf '%s\n' "$x25519_out" | grep -Ei "^(Public|Password)" | cut -d: -f2 | tr -d ' \r\n')

    if [ -z "$reality_private_key" ] || [ -z "$reality_public_key" ] || [ -z "$reality_uuid" ]; then
        cecho "${RED}错误：获取密钥或 UUID 失败。${PLAIN}"
        return 1
    fi
    return 0
}

collect_ss_params() {
    local exclude_ports="$1"
    cecho "${YELLOW}--- 配置 Shadowsocks ---${PLAIN}"

    printf "请输入 SS 端口 (默认随机 40000-65535): "
    read -r ss_port
    if [ -z "$ss_port" ]; then
        ss_port=$(get_free_random_port 40000 65535 "$exclude_ports")
    else
        if ! is_valid_port "$ss_port"; then
            cecho "${RED}错误：SS 端口 (${ss_port}) 无效！${PLAIN}"
            return 1
        fi
        if port_in_list "$ss_port" "$exclude_ports"; then
            cecho "${RED}错误：SS 端口 (${ss_port}) 与已有端口冲突！${PLAIN}"
            return 1
        fi
    fi

    cecho "请选择加密方式:"
    cecho "--- 2022 新版协议 (性能好，但对时间敏感) ---"
    cecho "1. 2022-blake3-aes-128-gcm"
    cecho "2. 2022-blake3-aes-256-gcm (推荐)"
    cecho "3. 2022-blake3-chacha20-poly1305"
    cecho "--- 经典通用协议 (兼容性最好) ---"
    cecho "4. aes-128-gcm"
    cecho "5. aes-256-gcm (常用)"
    cecho "6. chacha20-poly1305 (移动端推荐)"
    cecho "7. xchacha20-poly1305"

    printf "请选择 [1-7] (默认 2): "
    read -r ss_method_choice
    case "$ss_method_choice" in
        1) ss_method="2022-blake3-aes-128-gcm" ;;
        2) ss_method="2022-blake3-aes-256-gcm" ;;
        3) ss_method="2022-blake3-chacha20-poly1305" ;;
        4) ss_method="aes-128-gcm" ;;
        5) ss_method="aes-256-gcm" ;;
        6) ss_method="chacha20-poly1305" ;;
        7) ss_method="xchacha20-poly1305" ;;
        *) ss_method="2022-blake3-aes-256-gcm" ;;
    esac

    printf "请输入 SS 密码 (留空自动生成): "
    read -r ss_password
    if [ -z "$ss_password" ]; then
        ss_password=$(generate_ss_password "$ss_method")
    fi
    return 0
}

collect_vless_enc_params() {
    local exclude_ports="$1"
    cecho "${YELLOW}--- 配置 VLESS Encryption (原生后量子加密) ---${PLAIN}"

    printf "请输入 VLESS Encryption 端口 (默认随机 40000-65535): "
    read -r ve_port
    if [ -z "$ve_port" ]; then
        ve_port=$(get_free_random_port 40000 65535 "$exclude_ports")
    else
        if ! is_valid_port "$ve_port"; then
            cecho "${RED}错误：VLESS Encryption 端口 (${ve_port}) 无效！${PLAIN}"
            return 1
        fi
        if port_in_list "$ve_port" "$exclude_ports"; then
            cecho "${RED}错误：端口 (${ve_port}) 与已有端口冲突！${PLAIN}"
            return 1
        fi
    fi

    printf "请输入 UUID (留空自动随机生成): "
    read -r ve_uuid
    if [ -z "$ve_uuid" ]; then
        ve_uuid=$("$XRAY_BIN" uuid)
    elif ! is_valid_uuid "$ve_uuid"; then
        cecho "${RED}错误：输入的 UUID 格式无效！${PLAIN}"
        return 1
    fi

    printf "请输入流控 Flow (默认留空无流控，如需开启请手动输入如 xtls-rprx-vision): "
    read -r ve_flow

    cecho "请选择身份认证方式 (流量加密均为后量子安全):"
    cecho "1. X25519 (默认推荐，链接极短、支持二维码)"
    cecho "2. ML-KEM-768 (全链路后量子，字符串极长)"
    cecho "3. X25519 + ML-KEM-768 同时启用 (优点: 双重兜底防单一算法失效；缺点: 链接最长/无二维码/握手略重)"
    printf "请选择 [1-3] (默认 1): "
    read -r ve_auth_choice
    [ -z "$ve_auth_choice" ] && ve_auth_choice="1"

    cecho "${GREEN}正在生成 VLESS Encryption 密钥对...${PLAIN}"
    generate_vless_enc_keys "$ve_auth_choice" || return 1
    ve_decryption="$VE_DECRYPTION"
    ve_encryption="$VE_ENCRYPTION"
    return 0
}

# === 新增功能：在现有配置上无损加装新协议 ===
add_protocol() {
    if [ ! -f "$CONFIG_FILE" ]; then
        cecho "${RED}未找到现有配置文件 ($CONFIG_FILE)，请先使用选项 1 进行全新安装。${PLAIN}"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        install_dependencies
    fi

    local has_reality="false" has_ss="false" has_ve="false"
    [ -n "$(jq -c '.inbounds[] | select(.protocol == "vless" and .streamSettings.security == "reality")' "$CONFIG_FILE" | head -n 1)" ] && has_reality="true"
    [ -n "$(jq -c '.inbounds[] | select(.protocol == "shadowsocks")' "$CONFIG_FILE" | head -n 1)" ] && has_ss="true"
    [ -n "$(jq -c '.inbounds[] | select(.protocol == "vless" and (.settings.decryption // "none") != "none")' "$CONFIG_FILE" | head -n 1)" ] && has_ve="true"

    if [ "$has_reality" = "true" ] && [ "$has_ss" = "true" ] && [ "$has_ve" = "true" ]; then
        cecho "${YELLOW}当前已同时安装 Reality、Shadowsocks 和 VLESS Encryption，无需再加装。${PLAIN}"
        return 0
    fi

    cecho ""
    cecho "${GREEN}--- 无损加装新协议 (不影响现有节点配置) ---${PLAIN}"
    cecho "当前已装: Reality=${CYAN}${has_reality}${PLAIN} | SS=${CYAN}${has_ss}${PLAIN} | VLESS-Enc=${CYAN}${has_ve}${PLAIN}"
    cecho "1. 加装 Reality"
    cecho "2. 加装 Shadowsocks"
    cecho "3. 加装 VLESS Encryption"
    cecho "0. 返回主菜单"
    printf "请选择要加装的协议 [0-3]: "
    read -r add_choice
    [ "$add_choice" = "0" ] && return 2

    local existing_ports
    existing_ports=$(jq -r '.inbounds[].port' "$CONFIG_FILE" | tr '\n' ' ')

    local tmp_cfg next_cfg
    tmp_cfg=$(mktemp)
    cp "$CONFIG_FILE" "$tmp_cfg"
    next_cfg="${tmp_cfg}.next"

    case "$add_choice" in
        1)
            if [ "$has_reality" = "true" ]; then
                cecho "${YELLOW}Reality 已存在，如需调整请使用「修改节点信息」。${PLAIN}"
                rm -f "$tmp_cfg"
                return 0
            fi
            collect_reality_params "$existing_ports" || { rm -f "$tmp_cfg"; return 1; }
            jq --argjson rport "$reality_port" \
               --argjson iport "$reality_inner_port" \
               --arg uuid "$reality_uuid" \
               --arg sni "$reality_sni" \
               --arg pk "$reality_private_key" \
               --arg sid "$reality_shortid" \
               --arg dhost "$reality_dest_host" \
               --argjson dport "$reality_dest_port" \
               '.inbounds += [
                    {
                        "port": $rport,
                        "protocol": "vless",
                        "settings": {
                            "clients": [{"id": $uuid, "flow": "xtls-rprx-vision"}],
                            "decryption": "none"
                        },
                        "streamSettings": {
                            "network": "tcp",
                            "security": "reality",
                            "realitySettings": {
                                "dest": ("127.0.0.1:" + ($iport | tostring)),
                                "serverNames": [$sni],
                                "privateKey": $pk,
                                "shortIds": [$sid]
                            }
                        },
                        "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
                    },
                    {
                        "tag": "dokodemo-in",
                        "listen": "127.0.0.1",
                        "port": $iport,
                        "protocol": "dokodemo-door",
                        "settings": {"address": $dhost, "port": $dport, "network": "tcp"},
                        "sniffing": {"enabled": true, "destOverride": ["tls"], "routeOnly": true}
                    }
               ]
               | .routing.rules = [
                    {"inboundTag": ["dokodemo-in"], "domain": [$sni], "outboundTag": "direct"},
                    {"inboundTag": ["dokodemo-in"], "outboundTag": "block"}
               ] + .routing.rules' \
               "$tmp_cfg" > "$next_cfg" || { rm -f "$tmp_cfg" "$next_cfg"; return 1; }
            mv "$next_cfg" "$tmp_cfg"
            if apply_and_restart_config "$tmp_cfg"; then
                show_node_info
            fi
            ;;
        2)
            if [ "$has_ss" = "true" ]; then
                cecho "${YELLOW}Shadowsocks 已存在，如需调整请使用「修改节点信息」。${PLAIN}"
                rm -f "$tmp_cfg"
                return 0
            fi
            collect_ss_params "$existing_ports" || { rm -f "$tmp_cfg"; return 1; }
            jq --argjson port "$ss_port" \
               --arg method "$ss_method" \
               --arg pass "$ss_password" \
               '.inbounds += [
                    {
                        "port": $port,
                        "protocol": "shadowsocks",
                        "settings": {"method": $method, "password": $pass, "network": "tcp,udp"},
                        "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
                    }
               ]' \
               "$tmp_cfg" > "$next_cfg" || { rm -f "$tmp_cfg" "$next_cfg"; return 1; }
            mv "$next_cfg" "$tmp_cfg"
            if apply_and_restart_config "$tmp_cfg"; then
                show_node_info
            fi
            ;;
        3)
            if [ "$has_ve" = "true" ]; then
                cecho "${YELLOW}VLESS Encryption 已存在，如需调整请使用「修改节点信息」。${PLAIN}"
                rm -f "$tmp_cfg"
                return 0
            fi
            collect_vless_enc_params "$existing_ports" || { rm -f "$tmp_cfg"; return 1; }
            jq --argjson port "$ve_port" \
               --arg uuid "$ve_uuid" \
               --arg flow "$ve_flow" \
               --arg dec "$ve_decryption" \
               '.inbounds += [
                    {
                        "port": $port,
                        "protocol": "vless",
                        "settings": {
                            "clients": [
                                (if $flow != "" then {"id": $uuid, "flow": $flow} else {"id": $uuid} end)
                            ],
                            "decryption": $dec
                        },
                        "streamSettings": {"network": "raw", "security": "none"},
                        "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
                    }
               ]' \
               "$tmp_cfg" > "$next_cfg" || { rm -f "$tmp_cfg" "$next_cfg"; return 1; }
            mv "$next_cfg" "$tmp_cfg"
            if apply_and_restart_config "$tmp_cfg"; then
                save_node_metadata "" "" "$ve_encryption"
                show_node_info
            fi
            ;;
        *)
            cecho "${RED}无效选择。${PLAIN}"
            rm -f "$tmp_cfg"
            return 1
            ;;
    esac
}

# 配置生成主逻辑 (全新安装 / 彻底重置)
configure_xray() {
    install_dependencies
    install_xray || return 1

    cecho "${GREEN}请选择全新安装模式 (后续也可通过菜单选项 2 随时无损加装其他协议)：${PLAIN}"
    cecho "1. 仅安装 Reality"
    cecho "2. 仅安装 Shadowsocks"
    cecho "3. 仅安装 VLESS Encryption"
    cecho "4. 安装 Reality + Shadowsocks"
    cecho "5. 安装 Reality + VLESS Encryption"
    cecho "6. 安装 Reality + Shadowsocks + VLESS Encryption (全装)"
    printf "请输入选项 [1-6] (默认 1): "
    read -r install_mode
    [ -z "$install_mode" ] && install_mode="1"

    local want_reality="false" want_ss="false" want_ve="false"
    case "$install_mode" in
        1) want_reality="true" ;;
        2) want_ss="true" ;;
        3) want_ve="true" ;;
        4) want_reality="true"; want_ss="true" ;;
        5) want_reality="true"; want_ve="true" ;;
        6) want_reality="true"; want_ss="true"; want_ve="true" ;;
        *)
            cecho "${RED}无效选项，已取消配置。${PLAIN}"
            return 1
            ;;
    esac

    cecho "${GREEN}请选择默认出站策略：${PLAIN}"
    cecho "1. 优先/指定 IPv4 (IP4_out, 默认)"
    cecho "2. 优先/指定 IPv6 (IP6_out)"
    cecho "3. 系统自动适配 (direct, 适合纯 IPv6 或单栈机器)"
    printf "请输入选项 [1-3] (默认 1): "
    read -r out_choice
    case "$out_choice" in
        2) default_outbound="IP6_out" ;;
        3) default_outbound="direct" ;;
        *) default_outbound="IP4_out" ;;
    esac

    default_host=$(uname -n)
    printf "请输入节点名称备注 (默认: %s): " "$default_host"
    read -r custom_node_name
    [ -z "$custom_node_name" ] && custom_node_name="$default_host"

    local used_ports=""
    ve_encryption=""

    if [ "$want_reality" = "true" ]; then
        collect_reality_params "$used_ports" || return 1
        used_ports="$used_ports $reality_port $reality_inner_port"
    fi

    if [ "$want_ss" = "true" ]; then
        collect_ss_params "$used_ports" || return 1
        used_ports="$used_ports $ss_port"
    fi

    if [ "$want_ve" = "true" ]; then
        collect_vless_enc_params "$used_ports" || return 1
        used_ports="$used_ports $ve_port"
    fi

    cecho "${GREEN}正在生成配置文件...${PLAIN}"
    mkdir -p "$(dirname "$CONFIG_FILE")"
    local tmp_cfg need_comma="false"
    tmp_cfg=$(mktemp)

    cat > "$tmp_cfg" <<EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
EOF

    if [ "$want_reality" = "true" ]; then
        cat >> "$tmp_cfg" <<EOF
        {
            "port": $reality_port,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$reality_uuid",
                        "flow": "xtls-rprx-vision"
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
        need_comma="true"
    fi

    if [ "$want_ss" = "true" ]; then
        [ "$need_comma" = "true" ] && printf ',\n' >> "$tmp_cfg"
        cat >> "$tmp_cfg" <<EOF
        {
            "port": $ss_port,
            "protocol": "shadowsocks",
            "settings": {
                "method": "$ss_method",
                "password": "$ss_password",
                "network": "tcp,udp"
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": true
            }
        }
EOF
        need_comma="true"
    fi

    if [ "$want_ve" = "true" ]; then
        [ "$need_comma" = "true" ] && printf ',\n' >> "$tmp_cfg"
        local ve_flow_line=""
        [ -n "$ve_flow" ] && ve_flow_line=",\"flow\": \"$ve_flow\""
        cat >> "$tmp_cfg" <<EOF
        {
            "port": $ve_port,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$ve_uuid"$ve_flow_line
                    }
                ],
                "decryption": "$ve_decryption"
            },
            "streamSettings": {
                "network": "raw",
                "security": "none"
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

    if [ "$want_reality" = "true" ]; then
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
                    "geosite:cn"
                ],
                "outboundTag": "block"
            },
            {
                "ip": [
                    "geoip:cn",
                    "geoip:private"
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

    if apply_and_restart_config "$tmp_cfg"; then
        detected_ip=$(get_ip)
        save_node_metadata "$custom_node_name" "$detected_ip" "$ve_encryption"
        show_node_info
    fi
}

# 主菜单循环
main_menu() {
    detect_system

    while true; do
        cecho ""
        cecho "${GREEN}========== Xray 一键安装/管理脚本 (全系统通用 POSIX 版) ==========${PLAIN}"
        cecho "当前环境: 包管理器=${CYAN}${PKG_MGR}${PLAIN} | 服务管理=${CYAN}${INIT_SYS}${PLAIN}"
        cecho "1. 全新安装/重置 Xray 配置 (Reality / SS / VLESS Encryption)"
        cecho "2. 无损加装新协议 (不影响已安装的现有协议)"
        cecho "3. 查看当前已配置的节点信息、分享链接与二维码"
        cecho "4. 修改已配置的节点信息 (Reality / SS / VLESS-Enc / 出口策略)"
        cecho "5. 单独更新 Xray 内核"
        cecho "6. 卸载 Xray"
        cecho "0. 退出"
        cecho "=================================================================="

        printf "请选择 [0-6]: "
        read -r choice

        case "$choice" in
            1)
                configure_xray
                pause_and_return
                ;;
            2)
                add_protocol
                [ "$?" -ne 2 ] && pause_and_return
                ;;
            3)
                show_node_info
                pause_and_return
                ;;
            4)
                modify_node_info
                [ "$?" -ne 2 ] && pause_and_return
                ;;
            5)
                if install_xray && service_enable_and_restart; then
                    cecho "${GREEN}Xray 更新完成${PLAIN}"
                fi
                pause_and_return
                ;;
            6)
                uninstall_xray
                pause_and_return
                ;;
            0)
                cecho "${GREEN}已退出脚本。${PLAIN}"
                exit 0
                ;;
            *)
                cecho "${RED}无效选择，请输入 0-6 之间的数字。${PLAIN}"
                ;;
        esac
    done
}

main_menu
