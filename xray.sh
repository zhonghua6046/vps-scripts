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
    elif [ "$INIT_SYS" = "openrc" ] \vert{}\vert{} grep -Eq '^User=root$' /etc/systemd/system/xray.service 2>/dev/null; then
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
    printf '%s' "$1" \vert{} grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

# 校验 ShortId 格式 (2-16 位偶数长度十六进制字符)
is_valid_shortid() {
    printf '%s' "$1" \vert{} grep -Eq '^([0-9a-fA-F]{2}){1,8}$'
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

# 生成指定范围内未占用的随机端口 (支持排除 2 个指定端口)
get_free_random_port() {
    local min="$1"
    local max="${2:-65535}"
    local ex1="${3:-}"
    local ex2="${4:-}"
    local tries=0
    local candidate=""

    while [ "$tries" -lt 50 ]; do
        if command -v shuf >/dev/null 2>&1; then
            candidate=$(shuf -i "${min}-${max}" -n 1)
        else
            candidate=$(awk -v min="$min" -v max="$max" -v seed="$((tries +$$))" 'BEGIN{srand(seed); print int(min+rand()*(max-min+1))}')
        fi

        if [ "$candidate" != "$ex1" ] && [ "$candidate" != "$ex2" ] && ! is_port_in_use "$candidate"; then
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

# 保存节点元数据到本地 (权限 600，避免重复联网查询 IP)
save_node_metadata() {
    local node_name="$1"
    local server_ip="$2"
    mkdir -p "$(dirname "$INFO_FILE")"
    {
        printf "NODE_NAME='%s'\n" "$(escape_sq "$node_name")"
        printf "SERVER_IP='%s'\n" "$(escape_sq "$server_ip")"
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

    local custom_node_name=""
    local server_ip=""
    if [ -f "$INFO_FILE" ]; then
        # shellcheck disable=SC1090
        . "$INFO_FILE"
        custom_node_name="$NODE_NAME"
        server_ip="$SERVER_IP"
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

    local reality_json ss_json
    reality_json=$(jq -c '.inbounds[] | select(.protocol == "vless" and .streamSettings.security == "reality")' "$CONFIG_FILE" | head -n 1)
    ss_json=$(jq -c '.inbounds[] | select(.protocol == "shadowsocks")' "$CONFIG_FILE" | head -n 1)

    if [ -z "$reality_json" ] && [ -z "$ss_json" ]; then
        cecho "${RED}当前配置文件中未检测到 Reality 或 Shadowsocks 节点。${PLAIN}"
        return 1
    fi

    local has_both="false"
    if [ -n "$reality_json" ] && [ -n "$ss_json" ]; then
        has_both="true"
    fi

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
        if [ "$has_both" = "true" ]; then
            alias="${custom_node_name}-Reality"
        fi
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
        if [ "$has_both" = "true" ]; then
            ss_alias="${custom_node_name}-SS"
        fi
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

    # 1. 外网端口
    printf "外网端口 [当前: %s]: " "$cur_port"
    read -r new_port
    [ -z "$new_port" ] && new_port="$cur_port"
    if ! is_valid_port "$new_port"; then
        cecho "${RED}错误：外网端口号 (${new_port}) 无效，必须为 1-65535。${PLAIN}"
        return 1
    fi

    # 2. 内网回落端口 (仅新版防偷结构存在)
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

    # 3. 真实伪装目标
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

    # 4. SNI
    local sni_default="$cur_sni"
    if [ "$new_dest" != "$cur_dest" ]; then
        sni_default="$new_dest_host"
    fi
    printf "SNI 域名 serverName [默认: %s]: " "$sni_default"
    read -r new_sni
    [ -z "$new_sni" ] && new_sni="$sni_default"

    # 5. UUID (回车不变，auto 随机，或手动输入)
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

    # 6. ShortId (回车不变，auto 随机，或手动输入)
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

    # 7. 可选重置 X25519 密钥对
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

    # 使用 jq 局部更新 Reality + dokodemo-in + 联动 SNI 路由规则
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

    # 1. 端口
    printf "SS 端口 [当前: %s]: " "$cur_port"
    read -r new_port
    [ -z "$new_port" ] && new_port="$cur_port"
    if ! is_valid_port "$new_port"; then
        cecho "${RED}错误：端口号 (${new_port}) 无效，必须为 1-65535。${PLAIN}"
        return 1
    fi

    # 2. 加密方式
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

    # 3. 密码
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

    # 使用 jq 局部更新 SS 入站
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
        # 仅更新非 dokodemo-in 且非 block 的路由出口，避免误改回落转发规则
        jq --arg out "$new_out" \
           '(.routing.rules[] | select(((.inboundTag // []) | any(. == "dokodemo-in") | not) and .outboundTag != "block") | .outboundTag) = $out' \
           "$tmp_cfg" > "$next_cfg" || { rm -f "$next_cfg"; return 1; }
        mv "$next_cfg" "$tmp_cfg"
        return 0
    fi

    # 仅改了备注名，无需重启 Xray
    return 2
}

# 修改节点信息入口菜单 (区分 Reality / SS / 同时修改 / 公共设置)
modify_node_info() {
    if [ ! -f "$CONFIG_FILE" ]; then
        cecho "${RED}未找到配置文件 ($CONFIG_FILE)，请先执行选项 1 安装配置。${PLAIN}"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        cecho "${YELLOW}检测到缺少 jq，正在尝试自动安装...${PLAIN}"
        install_dependencies
    fi

    local has_reality="false"
    local has_ss="false"
    [ -n "$(jq -c '.inbounds[] | select(.protocol == "vless" and .streamSettings.security == "reality")' "$CONFIG_FILE" | head -n 1)" ] && has_reality="true"
    [ -n "$(jq -c '.inbounds[] | select(.protocol == "shadowsocks")' "$CONFIG_FILE" | head -n 1)" ] && has_ss="true"

    if [ "$has_reality" = "false" ] && [ "$has_ss" = "false" ]; then
        cecho "${RED}当前配置文件中未检测到可修改的 Reality 或 Shadowsocks 节点。${PLAIN}"
        return 1
    fi

    cecho ""
    cecho "${GREEN}--- 修改已配置的节点信息 ---${PLAIN}"
    cecho "当前已配置协议: Reality=${CYAN}${has_reality}${PLAIN} | Shadowsocks=${CYAN}${has_ss}${PLAIN}"
    cecho "1. 仅修改 Reality 节点"
    cecho "2. 仅修改 Shadowsocks 节点"
    cecho "3. 同时修改 Reality 和 Shadowsocks 节点"
    cecho "4. 修改默认出口策略 (IPv4/IPv6/自动适配) 或节点备注名"
    cecho "0. 返回主菜单"
    printf "请选择 [0-4]: "
    read -r mod_choice

    [ "$mod_choice" = "0" ] && return 0

    local tmp_cfg
    tmp_cfg=$(mktemp)
    cp "$CONFIG_FILE" "$tmp_cfg"

    case "$mod_choice" in
        1)
            if [ "$has_reality" = "false" ]; then
                cecho "${RED}当前未配置 Reality 节点，如需新增请使用主菜单选项 1。${PLAIN}"
                rm -f "$tmp_cfg"
                return 1
            fi
            edit_reality_in_tmp "$tmp_cfg" || { rm -f "$tmp_cfg"; return 1; }
            ;;
        2)
            if [ "$has_ss" = "false" ]; then
                cecho "${RED}当前未配置 Shadowsocks 节点，如需新增请使用主菜单选项 1。${PLAIN}"
                rm -f "$tmp_cfg"
                return 1
            fi
            edit_ss_in_tmp "$tmp_cfg" || { rm -f "$tmp_cfg"; return 1; }
            ;;
        3)
            if [ "$has_reality" = "false" ] || [ "$has_ss" = "false" ]; then
                cecho "${RED}当前未同时配置 Reality 和 Shadowsocks，无法选择同时修改。${PLAIN}"
                rm -f "$tmp_cfg"
                return 1
            fi
            edit_reality_in_tmp "$tmp_cfg" || { rm -f "$tmp_cfg"; return 1; }
            edit_ss_in_tmp "$tmp_cfg" || { rm -f "$tmp_cfg"; return 1; }
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

    # 检查最终 Reality 外网端口、内网回落端口与 SS 端口是否冲突
    local final_r_port final_i_port final_s_port
    final_r_port=$(jq -r '(.inbounds[] | select(.protocol == "vless" and .streamSettings.security == "reality") | .port) // empty' "$tmp_cfg" | head -n 1)
    final_i_port=$(jq -r '(.inbounds[] | select(.protocol == "dokodemo-door" and .settings.address != "127.0.0.1") | .port) // empty' "$tmp_cfg" | head -n 1)
    final_s_port=$(jq -r '(.inbounds[] | select(.protocol == "shadowsocks") | .port) // empty' "$tmp_cfg" | head -n 1)

    if [ -n "$final_r_port" ] && [ -n "$final_s_port" ] && [ "$final_r_port" = "$final_s_port" ]; then
        cecho "${RED}错误：Reality 外网端口与 Shadowsocks 端口 (${final_r_port}) 冲突，已放弃修改！${PLAIN}"
        rm -f "$tmp_cfg"
        return 1
    fi
    if [ -n "$final_i_port" ] && [ -n "$final_s_port" ] && [ "$final_i_port" = "$final_s_port" ]; then
        cecho "${RED}错误：Reality 内网回落端口与 Shadowsocks 端口 (${final_i_port}) 冲突，已放弃修改！${PLAIN}"
        rm -f "$tmp_cfg"
        return 1
    fi
    if [ -n "$final_r_port" ] && [ -n "$final_i_port" ] && [ "$final_r_port" = "$final_i_port" ]; then
        cecho "${RED}错误：Reality 外网端口与内网回落端口 (${final_r_port}) 冲突，已放弃修改！${PLAIN}"
        rm -f "$tmp_cfg"
        return 1
    fi

    # 校验、替换并重启 Xray，随后展示最新节点信息与二维码
    if apply_and_restart_config "$tmp_cfg"; then
        show_node_info
    fi
}

# 配置生成主逻辑 (全新安装 / 彻底重置)
configure_xray() {
    install_dependencies
    install_xray || return 1

    cecho "${GREEN}请选择安装模式：${PLAIN}"
    cecho "1. 仅安装 Reality"
    cecho "2. 仅安装 Shadowsocks"
    cecho "3. 安装 Reality + Shadowsocks (共存)"
    printf "请输入选项 [1-3] (默认 1): "
    read -r install_mode
    [ -z "$install_mode" ] && install_mode="1"
    case "$install_mode" in
        1|2|3) ;;
        *)
            cecho "${RED}无效选项，已取消配置。${PLAIN}"
            return 1
            ;;
    esac

    # === 公共配置收集 ===
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

    local reality_port=""
    local reality_inner_port=""

    # === Reality 配置收集 ===
    if [ "$install_mode" = "1" ] || [ "$install_mode" = "3" ]; then
        cecho "${YELLOW}--- 配置 Reality (新版防偷流量架构) ---${PLAIN}"

        # 外网端口
        printf "请输入 Reality 外网端口 (默认随机 40000-65535): "
        read -r reality_port
        if [ -z "$reality_port" ]; then
            reality_port=$(get_free_random_port 40000 65535)
        elif ! is_valid_port "$reality_port"; then
            cecho "${RED}错误：Reality 外网端口 (${reality_port}) 无效！${PLAIN}"
            return 1
        fi

        # 内网回落端口 (支持手动输入，默认随机且防冲突)
        printf "请输入 Reality 内网回落端口 (仅监听 127.0.0.1，默认随机 20000-39999): "
        read -r reality_inner_port
        if [ -z "$reality_inner_port" ]; then
            reality_inner_port=$(get_free_random_port 20000 39999 "$reality_port")
        else
            if ! is_valid_port "$reality_inner_port"; then
                cecho "${RED}错误：Reality 内网回落端口 (${reality_inner_port}) 无效！${PLAIN}"
                return 1
            fi
            if [ "$reality_inner_port" = "$reality_port" ]; then
                cecho "${RED}错误：内网回落端口不能与外网端口 (${reality_port}) 相同！${PLAIN}"
                return 1
            fi
        fi

        # 真实伪装目标
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

        # UUID (支持手动输入，留空默认随机)
        printf "请输入 UUID (留空自动随机生成): "
        read -r reality_uuid
        if [ -z "$reality_uuid" ]; then
            reality_uuid=$("$XRAY_BIN" uuid)
        elif ! is_valid_uuid "$reality_uuid"; then
            cecho "${RED}错误：输入的 UUID 格式无效！${PLAIN}"
            return 1
        fi

        # ShortId (支持手动输入，留空默认随机)
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
    fi

    # === SS 配置收集 ===
    if [ "$install_mode" = "2" ] || [ "$install_mode" = "3" ]; then
        cecho "${YELLOW}--- 配置 Shadowsocks ---${PLAIN}"

        printf "请输入 SS 端口 (默认随机 40000-65535): "
        read -r ss_port
        if [ -z "$ss_port" ]; then
            ss_port=$(get_free_random_port 40000 65535 "$reality_port" "$reality_inner_port")
        else
            if ! is_valid_port "$ss_port"; then
                cecho "${RED}错误：SS 端口 (${ss_port}) 无效！${PLAIN}"
                return 1
            fi
            if [ "$install_mode" = "3" ] && { [ "$ss_port" = "$reality_port" ] || [ "$ss_port" = "$reality_inner_port" ]; }; then
                cecho "${RED}错误：SS 端口不能与 Reality 外网/内网端口冲突！${PLAIN}"
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
    fi

    # === 生成临时配置文件并原子校验应用 ===
    cecho "${GREEN}正在生成配置文件...${PLAIN}"
    mkdir -p "$(dirname "$CONFIG_FILE")"
    local tmp_cfg
    tmp_cfg=$(mktemp)

    cat > "$tmp_cfg" <<EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
EOF

    if [ "$install_mode" = "1" ] || [ "$install_mode" = "3" ]; then
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
    fi

    if [ "$install_mode" = "3" ]; then
        printf ',\n' >> "$tmp_cfg"
    fi

    if [ "$install_mode" = "2" ] || [ "$install_mode" = "3" ]; then
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

    if [ "$install_mode" = "1" ] || [ "$install_mode" = "3" ]; then
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

    if apply_and_restart_config "$tmp_cfg"; then
        detected_ip=$(get_ip)
        save_node_metadata "$custom_node_name" "$detected_ip"
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
        cecho "1. 安装/重置 Xray 配置 (Reality / SS)"
        cecho "2. 查看当前已配置的节点信息、分享链接与二维码"
        cecho "3. 修改已配置的节点信息 (Reality / SS / 出口策略)"
        cecho "4. 单独更新 Xray 内核"
        cecho "5. 卸载 Xray"
        cecho "0. 退出"
        cecho "=================================================================="

        printf "请选择 [0-5]: "
        read -r choice

        case "$choice" in
            1)
                configure_xray
                pause_and_return
                ;;
            2)
                show_node_info
                pause_and_return
                ;;
            3)
                modify_node_info
                pause_and_return
                ;;
            4)
                if install_xray && service_enable_and_restart; then
                    cecho "${GREEN}Xray 更新完成${PLAIN}"
                fi
                pause_and_return
                ;;
            5)
                uninstall_xray
                pause_and_return
                ;;
            0)
                cecho "${GREEN}已退出脚本。${PLAIN}"
                exit 0
                ;;
            *)
                cecho "${RED}无效选择，请输入 0-5 之间的数字。${PLAIN}"
                ;;
        esac
    done
}

main_menu
