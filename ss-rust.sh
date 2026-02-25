#!/bin/bash

# ==================================================
# Shadowsocks-Rust 管理脚本 (V8 - 依赖修复版)
# ==================================================

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
PLAIN='\033[0m'

# 路径定义
BIN_PATH="/usr/local/bin"
CONFIG_DIR="/etc/shadowsocks-rust"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SYSTEMD_FILE="/etc/systemd/system/shadowsocks-rust.service"
OPENRC_FILE="/etc/init.d/shadowsocks-rust"

# 检查 Root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：请使用 sudo 或 root 用户运行此脚本！${PLAIN}"
   exit 1
fi

# ================= 系统检测函数 =================

check_sys_type() {
    if [[ -f /etc/alpine-release ]]; then
        RELEASE="alpine"
        INIT_SYSTEM="openrc"
        LIBC_TYPE="musl"
    elif [[ -f /etc/redhat-release ]]; then
        RELEASE="centos"
        INIT_SYSTEM="systemd"
        LIBC_TYPE="gnu"
    elif cat /etc/issue | grep -q -E -i "debian|ubuntu"; then
        RELEASE="debian"
        INIT_SYSTEM="systemd"
        LIBC_TYPE="gnu"
    else
        RELEASE="unknown"
        INIT_SYSTEM="systemd"
        LIBC_TYPE="gnu"
    fi
}
# 初始化检测
check_sys_type

# ================= 服务管理封装 =================

svc_start() {
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service shadowsocks-rust start
    else
        systemctl start shadowsocks-rust
    fi
}

svc_stop() {
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service shadowsocks-rust stop
    else
        systemctl stop shadowsocks-rust
    fi
}

svc_restart() {
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service shadowsocks-rust restart
    else
        systemctl restart shadowsocks-rust
    fi
}

svc_enable() {
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-update add shadowsocks-rust default
    else
        systemctl enable shadowsocks-rust
    fi
}

svc_disable() {
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-update del shadowsocks-rust default
    else
        systemctl disable shadowsocks-rust
    fi
}

svc_status() {
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service shadowsocks-rust status
    else
        systemctl status shadowsocks-rust --no-pager
    fi
}

svc_is_active() {
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service shadowsocks-rust status | grep -q "started"
    else
        systemctl is-active --quiet shadowsocks-rust
    fi
}

# ================= 工具函数 =================

separator() {
    echo -e "\n${BLUE}==================================================${PLAIN}\n"
}

pause() {
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    echo ""
    separator
}

url_encode() {
    local string="${1}"
    local strlen=${#string}
    local encoded=""
    local pos c o
    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * )               printf -v o '%%%02x' "'$c"
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

# 智能获取 IP
get_public_ip() {
    local ipv4=$(curl -s4m3 ip.sb)
    if [[ -n "$ipv4" ]]; then echo "$ipv4"; return; fi
    local ipv6=$(curl -s6m3 ip.sb)
    if [[ -n "$ipv6" ]]; then echo "$ipv6"; return; fi
    echo "无法自动获取IP"
}

# 检查依赖 (修复：确保优先执行)
check_deps() {
    echo -e "${GREEN}正在检查依赖 (${RELEASE})...${PLAIN}"
    if [[ "$RELEASE" == "alpine" ]]; then
        echo -e "${GREEN}更新 apk 仓库并安装依赖...${PLAIN}"
        apk update
        apk add --no-cache curl wget jq tar xz openssl lsof coreutils
    elif [[ "$RELEASE" == "centos" ]]; then
        yum install -y curl wget jq tar xz openssl lsof
    else
        apt-get install -y curl wget jq tar xz-utils openssl lsof
    fi
    
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}错误：依赖安装失败 (jq not found)，脚本无法继续。${PLAIN}"
        exit 1
    fi
}

get_meta_data() {
    ARCH=$(uname -m)
    if [[ "$LIBC_TYPE" == "musl" ]]; then
        TARGET_ARCH="${ARCH}-unknown-linux-musl"
    else
        TARGET_ARCH="${ARCH}-unknown-linux-gnu"
    fi

    echo -e "系统环境: ${YELLOW}${RELEASE} (${LIBC_TYPE})${PLAIN}"
    echo -e "目标架构: ${YELLOW}${TARGET_ARCH}${PLAIN}"
    echo -e "正在查询 GitHub 最新版本..."
    
    local API_URL="https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest"
    local LATEST_JSON=$(curl -s "${API_URL}")
    
    LATEST_TAG_RAW=$(echo "$LATEST_JSON" | jq -r .tag_name)
    LATEST_TAG=${LATEST_TAG_RAW#v} 
    
    LATEST_URL=$(echo "$LATEST_JSON" | jq -r ".assets[] | select(.name | contains(\"${TARGET_ARCH}\")) | .browser_download_url" | grep ".tar.xz$")
    
    if [[ -z "$LATEST_URL" ]]; then
        echo -e "${RED}获取失败！未找到适配 ${TARGET_ARCH} 的版本。${PLAIN}"
        exit 1
    fi
}

install_binaries() {
    # 这里的 check_deps 是为了复用，但主流程里已经前置调用了
    echo -e "${GREEN}正在下载版本 ${LATEST_TAG}...${PLAIN}"
    wget -O /tmp/ss-rust.tar.xz "$LATEST_URL"
    echo -e "${GREEN}正在解压安装...${PLAIN}"
    mkdir -p /tmp/ss-rust
    tar -xf /tmp/ss-rust.tar.xz -C /tmp/ss-rust
    find /tmp/ss-rust -type f -name "ss*" -exec mv {} ${BIN_PATH}/ \;
    chmod +x ${BIN_PATH}/ss*
    rm -rf /tmp/ss-rust /tmp/ss-rust.tar.xz
}

install_service() {
    rm -f ${SYSTEMD_FILE} ${OPENRC_FILE}

    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        echo -e "${GREEN}正在创建 OpenRC 服务脚本 (Alpine专用)...${PLAIN}"
        cat > ${OPENRC_FILE} <<EOF
#!/sbin/openrc-run

name="shadowsocks-rust"
description="Shadowsocks-Rust Server Service"
command="${BIN_PATH}/ssserver"
command_args="-c ${CONFIG_FILE}"
command_background=true
pidfile="/run/shadowsocks-rust.pid"
rc_ulimit="-n 51200"

depend() {
    need net
    use dns logger
    after net
}
EOF
        chmod +x ${OPENRC_FILE}
    else
        echo -e "${GREEN}正在创建 Systemd 服务脚本...${PLAIN}"
        cat > ${SYSTEMD_FILE} <<EOF
[Unit]
Description=Shadowsocks-Rust Server Service
After=network.target

[Service]
Type=simple
ExecStart=${BIN_PATH}/ssserver -c ${CONFIG_FILE}
Restart=on-failure
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi
    
    svc_enable
}

install_full() {
    # 修复核心：先把依赖装好，才有 jq 用
    check_deps
    
    # 依赖装好后，再获取元数据
    get_meta_data
    install_binaries
    
    if [[ ! -d ${CONFIG_DIR} ]]; then mkdir -p ${CONFIG_DIR}; fi
    if [[ ! -f ${CONFIG_FILE} ]]; then echo '{"servers": []}' > ${CONFIG_FILE}; fi
    
    install_service
    
    echo -e "${GREEN}安装完成！即将进入节点配置...${PLAIN}"
    sleep 1
    add_node_logic
}

# ================= 核心：添加节点逻辑 =================
add_node_logic() {
    echo -e "\n${BLUE}========== 配置新节点 ==========${PLAIN}"
    
    # 1. 协议选择
    echo -e "请选择加密协议:"
    echo -e "  1) aes-128-gcm"
    echo -e "  2) aes-256-gcm"
    echo -e "  3) chacha20-ietf-poly1305"
    echo -e "  4) 2022-blake3-aes-128-gcm"
    echo -e "  5) 2022-blake3-aes-256-gcm"
    echo -e "  6) 2022-blake3-chacha20-poly1305"
    
    read -p "请输入数字 [1-6] (默认2): " method_num
    case $method_num in
        1) METHOD="aes-128-gcm" ;;
        3) METHOD="chacha20-ietf-poly1305" ;;
        4) METHOD="2022-blake3-aes-128-gcm" ;;
        5) METHOD="2022-blake3-aes-256-gcm" ;;
        6) METHOD="2022-blake3-chacha20-poly1305" ;;
        *) METHOD="aes-256-gcm" ;;
    esac
    echo -e "已选择协议: ${YELLOW}$METHOD${PLAIN}"

    # 2. 监听地址
    echo -e "\n请选择监听地址 (Listen Address):"
    echo -e "  1) 0.0.0.0 (IPv4 Only / 传统)"
    echo -e "  2) ::      (IPv6 Only / 双栈 - 纯v6机器选这个)"
    read -p "请输入数字 [1-2] (默认1): " listen_num
    if [[ "$listen_num" == "2" ]]; then
        SERVER_ADDR="::"
        echo -e "监听地址: ${YELLOW}[::]${PLAIN}"
    else
        SERVER_ADDR="0.0.0.0"
        echo -e "监听地址: ${YELLOW}0.0.0.0${PLAIN}"
    fi

    # 3. 出站策略
    echo -e "\n请选择出站流量优先级 (Outbound Priority):"
    echo -e "  1) IPv4 优先 (默认 - ipv6_first: false)"
    echo -e "  2) IPv6 优先 (ipv6_first: true)"
    read -p "请输入数字 [1-2] (默认1): " prio_num
    if [[ "$prio_num" == "2" ]]; then
        V6_FIRST="true"
        echo -e "流量策略: ${YELLOW}IPv6 优先${PLAIN}"
    else
        V6_FIRST="false"
        echo -e "流量策略: ${YELLOW}IPv4 优先${PLAIN}"
    fi

    # 4. 端口
    while true; do
        echo -e "\n请输入端口号 (1024-65535)"
        read -p "留空则自动生成 (20000+): " input_port
        if [[ -z "$input_port" ]]; then
            PORT=$(shuf -i 20000-60000 -n 1)
        else
            PORT=$input_port
        fi
        if lsof -i :$PORT > /dev/null; then
            echo -e "${RED}端口 $PORT 已被占用，请更换！${PLAIN}"
        else
            echo -e "使用端口: ${YELLOW}$PORT${PLAIN}"
            break
        fi
    done

    # 5. 密码
    echo -e "\n请输入密码"
    if [[ "$METHOD" == *"2022"* ]]; then
        echo -e "${YELLOW}提示: SS-2022 协议建议使用自动生成。${PLAIN}"
    fi
    read -p "留空则自动生成: " input_pwd
    if [[ -z "$input_pwd" ]]; then
        if [[ "$METHOD" == *"2022"* ]]; then
            PASSWORD=$(openssl rand -base64 32)
        else
            PASSWORD=$(openssl rand -base64 16)
        fi
        echo -e "已自动生成密码: ${YELLOW}${PASSWORD}${PLAIN}"
    else
        PASSWORD=$input_pwd
        echo -e "使用密码: ${YELLOW}${PASSWORD}${PLAIN}"
    fi

    # 6. 名称
    echo -e "\n请输入节点名称 (用于备注)"
    read -p "留空默认为 \"SS-端口号\": " input_name
    if [[ -z "$input_name" ]]; then
        NODE_NAME="SS-${PORT}"
    else
        NODE_NAME="$input_name"
    fi

    # 写入配置
    TMP_JSON=$(mktemp)
    jq ".servers += [{\"server\": \"$SERVER_ADDR\", \"server_port\": $PORT, \"password\": \"$PASSWORD\", \"method\": \"$METHOD\", \"mode\": \"tcp_and_udp\", \"ipv6_first\": $V6_FIRST}]" ${CONFIG_FILE} > "$TMP_JSON" && mv "$TMP_JSON" ${CONFIG_FILE}
    
    echo -e "${GREEN}正在重启服务...${PLAIN}"
    svc_restart
    sleep 1
    
    if svc_is_active; then
        show_single_link "$PORT" "$PASSWORD" "$METHOD" "$NODE_NAME" "$SERVER_ADDR"
    else
        echo -e "${RED}启动失败！请检查日志。${PLAIN}"
        svc_status
    fi
}

show_single_link() {
    local port=$1
    local pwd=$2
    local method=$3
    local name=$4
    local listen_addr=$5
    
    local public_ip=$(get_public_ip)
    if [[ "$public_ip" == "无法自动获取IP" ]]; then
        read -p "无法自动获取公网 IP，请输入服务器 IP: " manual_ip
        public_ip=$manual_ip
    fi

    local raw="${method}:${pwd}@${public_ip}:${port}"
    local b64=$(echo -n "${raw}" | base64 -w 0)
    local encoded_name=$(url_encode "$name")
    local link="ss://${b64}#${encoded_name}"
    
    echo -e "\n${YELLOW}============== 节点分享 ==============${PLAIN}"
    echo -e "节点名称: ${GREEN}${name}${PLAIN}"
    echo -e "服务器IP: ${public_ip}"
    echo -e "端口: ${port}"
    echo -e "密码: ${pwd}"
    echo -e "协议: ${method}"
    echo -e "监听地址: ${listen_addr}"
    echo -e "----------------------------------------"
    echo -e "SS 链接: ${GREEN}${link}${PLAIN}"
    echo -e "${YELLOW}========================================${PLAIN}"
}

list_nodes() {
    if [[ ! -f ${CONFIG_FILE} ]]; then echo -e "${RED}无配置文件！${PLAIN}"; return; fi
    local count=$(jq '.servers | length' ${CONFIG_FILE})
    echo -e "\n当前共有 $count 个节点:"
    for ((i=0; i<$count; i++)); do
        local p=$(jq -r ".servers[$i].server_port" ${CONFIG_FILE})
        local m=$(jq -r ".servers[$i].method" ${CONFIG_FILE})
        local w=$(jq -r ".servers[$i].password" ${CONFIG_FILE})
        local s=$(jq -r ".servers[$i].server" ${CONFIG_FILE})
        show_single_link "$p" "$w" "$m" "Node-$p" "$s"
    done
}

update_core() {
    # 修复升级逻辑：同样要先检查依赖
    check_deps
    get_meta_data 
    if command -v ${BIN_PATH}/ssserver >/dev/null; then
        CURRENT_VER_RAW=$(${BIN_PATH}/ssserver --version | awk '{print $2}')
        CURRENT_VER=${CURRENT_VER_RAW#v}
    else
        CURRENT_VER="未安装"
    fi
    echo -e "当前版本: ${BLUE}${CURRENT_VER}${PLAIN}"
    echo -e "最新版本: ${GREEN}${LATEST_TAG}${PLAIN}"
    if [[ "$CURRENT_VER" == "$LATEST_TAG" ]]; then
        echo -e "${YELLOW}当前已是最新版本，无需升级。${PLAIN}"
        read -p "是否强制重新安装？[y/N] (默认N): " yn
    else
        echo -e "${GREEN}发现新版本！${PLAIN}"
        read -p "是否立即升级？[y/N] (默认N): " yn
    fi
    yn=${yn:-n}
    if [[ "$yn" == "y" || "$yn" == "Y" ]]; then
        echo "停止服务..."
        svc_stop
        install_binaries
        svc_restart
        echo -e "${GREEN}升级成功！服务已重启。${PLAIN}"
    else
        echo "已取消升级。"
    fi
}

uninstall_core() {
    echo -e "\n${RED}警告：此操作将删除所有 SS 服务和配置文件！${PLAIN}"
    read -p "确认卸载吗？[y/N] (默认N): " confirm
    confirm=${confirm:-n}
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        svc_stop
        svc_disable
        if [[ "$INIT_SYSTEM" == "systemd" ]]; then
            rm -f ${SYSTEMD_FILE}
            systemctl daemon-reload
        else
            rm -f ${OPENRC_FILE}
        fi
        rm -f ${BIN_PATH}/ss*
        rm -rf ${CONFIG_DIR}
        echo -e "${GREEN}已成功卸载。${PLAIN}"
    else
        echo -e "${YELLOW}操作已取消。${PLAIN}"
    fi
}

while true; do
    separator
    echo -e "   Shadowsocks-Rust 管理脚本       "
    echo -e "----------------------------------"
    echo -e " 1. 安装服务 (全新安装)"
    echo -e " 2. 添加节点 (支持 v6 / OpenRC)"
    echo -e " 3. 查看节点 (获取链接)"
    echo -e " 4. 升级内核 (版本检测)"
    echo -e " 5. 卸载服务"
    echo -e " 0. 退出脚本"
    echo -e "----------------------------------"
    read -p " 请选择: " choice
    case "$choice" in
        1) install_full; pause ;;
        2) 
            if [[ ! -f ${CONFIG_FILE} ]]; then echo -e "${RED}请先安装！${PLAIN}"; else add_node_logic; fi
            pause 
            ;;
        3) list_nodes; pause ;;
        4) update_core; pause ;;
        5) uninstall_core; pause ;;
        0) exit 0 ;;
        *) echo "无效选择"; ;;
    esac
done
