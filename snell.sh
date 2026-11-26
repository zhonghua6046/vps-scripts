#!/bin/bash

# --- 变量及路径定义 ---

# 默认目标版本号
VERSION="v6.0.0"

# 常规护眼配色 (绿/黄/红 + 默认前景色)
Green="\033[32m"
Yellow="\033[33m"
Red="\033[31m"
Reset="\033[0m"

Info="${Green}[信息]${Reset}"
Warn="${Yellow}[提示]${Reset}"
Error="${Red}[错误]${Reset}"

SNELL_USER="snell"
SNELL_BIN_FILE="/usr/local/bin/snell-server"
SNELL_CONFIG_DIR="/etc/snell"
SNELL_CONFIG_FILE="/etc/snell/snell-server.conf"
SNELL_SERVICE_FILE="/etc/systemd/system/snell.service"
LEGACY_SERVICE_FILE="/lib/systemd/system/snell.service"

# --- 基础工具函数 ---

check_root(){
    if [[ $EUID -ne 0 ]]; then
        echo -e "${Error} 当前非 ROOT 账号，请使用 ${Green}sudo -i${Reset} 或 root 权限运行。"
        exit 1
    fi
}

check_package_manager(){
    if command -v apt-get >/dev/null 2>&1; then
        PM="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PM="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PM="yum"
    else
        echo -e "${Error} 未知的包管理器，脚本无法继续。"
        exit 1
    fi
}

install_dependencies(){
    echo -e "${Info} 正在检查运行依赖 (wget, unzip, curl)..."
    local missing=()
    for cmd in wget unzip curl; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if [ ${#missing[@]} -eq 0 ]; then
        echo -e "${Info} 依赖检查通过，所有必要工具均已安装。"
        return 0
    fi

    check_package_manager
    echo -e "${Info} 检测到缺失依赖: ${Yellow}${missing[*]}${Reset}，正在通过 ${Yellow}${PM}${Reset} 安装..."
    if [ "$PM" = "apt" ]; then
        apt-get update -qq && apt-get install -y -qq "${missing[@]}"
    else
        "$PM" install -y -q "${missing[@]}"
    fi
    echo -e "${Info} 缺失依赖安装完成。"
}

ensure_snell_user(){
    if ! id -u "$SNELL_USER" >/dev/null 2>&1; then
        local nologin_bin="/usr/sbin/nologin"
        [ ! -x "$nologin_bin" ] && nologin_bin="/sbin/nologin"
        [ ! -x "$nologin_bin" ] && nologin_bin="/bin/false"
        echo -e "${Info} 正在创建专用系统用户 ${Yellow}${SNELL_USER}${Reset} (无登录权限)..."
        useradd --system --no-create-home --shell "$nologin_bin" "$SNELL_USER"
        echo -e "${Info} 系统用户 ${Yellow}${SNELL_USER}${Reset} 创建完成。"
    else
        echo -e "${Info} 系统用户 ${Yellow}${SNELL_USER}${Reset} 已存在，跳过创建。"
    fi
}

# 生成 32 位带符号强密码（剔除 # ; , = $ 等注释或分隔符）
generate_strong_psk(){
    LC_ALL=C tr -dc 'A-Za-z0-9!@%^&*()_+-' </dev/urandom | head -c 32
}

generate_random_port(){
    echo $((RANDOM % 45536 + 20000))
}

validate_port(){
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

get_public_ip(){
    local ip
    ip=$(curl -s4 -m 5 https://api.ipify.org 2>/dev/null \
      || curl -s4 -m 5 https://ip.sb 2>/dev/null \
      || wget -qO- -t 1 -T 5 https://api.ipify.org 2>/dev/null \
      || true)
    echo "${ip:-您的服务器IP}"
}

get_installed_version(){
    if [ -x "$SNELL_BIN_FILE" ]; then
        local ver_output
        ver_output=$("$SNELL_BIN_FILE" -v 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+([a-zA-Z0-9.-]*)?' | head -n 1 || true)
        echo "${ver_output:-未知版本}"
    else
        echo "未安装"
    fi
}

get_service_status_text(){
    if [ ! -f "$SNELL_BIN_FILE" ]; then
        echo -e "${Yellow}未安装${Reset}"
    elif systemctl is-active --quiet snell; then
        echo -e "${Green}运行中${Reset}"
    else
        echo -e "${Red}已停止${Reset}"
    fi
}

# 安全读取配置文件字段
read_conf_val(){
    local key="$1"
    local default_val="${2:-}"
    local val
    val=$(grep -E "^${key}[[:space:]]*=" "$SNELL_CONFIG_FILE" 2>/dev/null | head -n 1 | sed -E "s/^${key}[[:space:]]*=[[:space:]]*//;s/[[:space:]]*$//" || true)
    echo "${val:-$default_val}"
}

read_conf_remark(){
    local val
    val=$(grep -E "^#[[:space:]]*remark[[:space:]]*=" "$SNELL_CONFIG_FILE" 2>/dev/null | head -n 1 | sed -E 's/^#[[:space:]]*remark[[:space:]]*=[[:space:]]*//;s/[[:space:]]*$//' || true)
    echo "${val:-Snell-Server}"
}

# 交互选择传输模式
prompt_mode(){
    local current="${1:-default}"
    local choice
    echo -e "\n请选择传输模式 (mode) [当前/默认: ${Yellow}${current}${Reset}]:" >&2
    echo -e "  ${Green}1.${Reset} default    - 默认：流量特征混淆 + AES 加密" >&2
    echo -e "  ${Green}2.${Reset} unshaped   - 关闭混淆，仅 AES 加密，吞吐提升约 10%" >&2
    echo -e "  ${Green}3.${Reset} unsafe-raw - 明文无加密，仅限内网或安全隧道落地" >&2
    echo -ne "请输入选项 [1-3，回车保留 ${Yellow}${current}${Reset}]: " >&2
    read -r choice
    case "$choice" in
        1) echo "default" ;;
        2) echo "unshaped" ;;
        3) echo "unsafe-raw" ;;
        *) echo "$current" ;;
    esac
}

# 交互选择 DNS 出站 IP 偏好
prompt_dns_pref(){
    local current="${1:-default}"
    local choice
    echo -e "\n请选择 DNS 出站 IP 偏好 (dns-ip-preference) [当前/默认: ${Yellow}${current}${Reset}]:" >&2
    echo -e "  ${Green}1.${Reset} default" >&2
    echo -e "  ${Green}2.${Reset} prefer-ipv4" >&2
    echo -e "  ${Green}3.${Reset} prefer-ipv6" >&2
    echo -e "  ${Green}4.${Reset} ipv4-only" >&2
    echo -e "  ${Green}5.${Reset} ipv6-only" >&2
    echo -ne "请输入选项 [1-5，回车保留 ${Yellow}${current}${Reset}]: " >&2
    read -r choice
    case "$choice" in
        1) echo "default" ;;
        2) echo "prefer-ipv4" ;;
        3) echo "prefer-ipv6" ;;
        4) echo "ipv4-only" ;;
        5) echo "ipv6-only" ;;
        *) echo "$current" ;;
    esac
}

# 写入配置文件并收紧权限
write_config(){
    local remark="$1"
    local listen="$2"
    local psk="$3"
    local ipv6="$4"
    local mode="$5"
    local dns_pref="$6"

    ensure_snell_user
    echo -e "${Info} 正在创建配置目录并写入配置文件: ${Yellow}${SNELL_CONFIG_FILE}${Reset}..."
    mkdir -p "$SNELL_CONFIG_DIR"

    cat > "$SNELL_CONFIG_FILE" <<EOF
[snell-server]
# remark = ${remark}
listen = ${listen}
psk = ${psk}
ipv6 = ${ipv6}
mode = ${mode}
dns-ip-preference = ${dns_pref}
EOF

    echo -e "${Info} 正在配置目录与文件权限 (属主 root:${SNELL_USER}，目录 750，配置 640)..."
    chown root:"$SNELL_USER" "$SNELL_CONFIG_DIR" "$SNELL_CONFIG_FILE"
    chmod 750 "$SNELL_CONFIG_DIR"
    chmod 640 "$SNELL_CONFIG_FILE"
    echo -e "${Info} 配置文件写入并校准权限完成。"
}

# 写入 Systemd 服务文件
write_systemd_service(){
    ensure_snell_user
    if [ -f "$LEGACY_SERVICE_FILE" ]; then
        echo -e "${Info} 清理旧路径服务文件: ${Yellow}${LEGACY_SERVICE_FILE}${Reset}..."
        rm -f "$LEGACY_SERVICE_FILE"
    fi

    echo -e "${Info} 正在写入 Systemd 服务文件: ${Yellow}${SNELL_SERVICE_FILE}${Reset}..."
    cat > "$SNELL_SERVICE_FILE" <<EOF
[Unit]
Description=Snell Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SNELL_USER}
Group=${SNELL_USER}
LimitNOFILE=32768
ExecStart=${SNELL_BIN_FILE} -c ${SNELL_CONFIG_FILE}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Restart=on-failure
RestartSec=5
SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF
    echo -e "${Info} 正在重载 Systemd 配置 (systemctl daemon-reload)..."
    systemctl daemon-reload
    echo -e "${Info} Systemd 服务配置完成。"
}

# 核心下载逻辑：临时目录下载、解压并校验
download_snell_to_tmp(){
    local target_ver="${1:-$VERSION}"
    local arch arch_name arch_url tmp_dir bin_ver

    echo -e "${Info} 正在检测服务器 CPU 架构..." >&2
    arch=$(uname -m)
    case "$arch" in
        x86_64)          arch_name="amd64" ;;
        i386 | i686)     arch_name="i386" ;;
        aarch64 | arm64) arch_name="aarch64" ;;
        *)
            echo -e "${Error} 不支持的服务器架构: ${Yellow}${arch}${Reset} (Snell v6 仅支持 amd64 / i386 / aarch64)" >&2
            return 1
            ;;
    esac

    arch_url="https://dl.nssurge.com/snell/snell-server-${target_ver}-linux-${arch_name}.zip"
    tmp_dir=$(mktemp -d)

    echo -e "${Info} 架构识别为 ${Yellow}${arch} (${arch_name})${Reset}，准备下载 Snell Server ${Yellow}${target_ver}${Reset}" >&2
    echo -e "${Info} 下载地址: ${arch_url}" >&2
    if ! wget -q --show-progress -O "${tmp_dir}/snell-server.zip" "$arch_url"; then
        echo -e "${Error} 下载失败，请检查网络连接或确认版本号 ${Yellow}${target_ver}${Reset} 是否存在。" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    echo -e "${Info} 下载完成，正在临时目录解压文件..." >&2
    if ! unzip -qo "${tmp_dir}/snell-server.zip" -d "$tmp_dir"; then
        echo -e "${Error} 解压失败，下载的压缩包可能已损坏。" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    if [ ! -f "${tmp_dir}/snell-server" ]; then
        echo -e "${Error} 压缩包中未找到 snell-server 二进制文件。" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    echo -e "${Info} 正在赋予执行权限并校验二进制文件可用性..." >&2
    chmod +x "${tmp_dir}/snell-server"
    bin_ver=$("${tmp_dir}/snell-server" -v 2>&1 | head -n 1 || true)
    if [ -z "$bin_ver" ]; then
        echo -e "${Error} 二进制文件校验失败，无法在当前系统运行。" >&2
        rm -rf "$tmp_dir"
        return 1
    fi
    echo -e "${Info} 二进制校验通过: ${Green}${bin_ver}${Reset}" >&2

    echo "$tmp_dir"
}

# --- 菜单核心功能 ---

install_snell(){
    if [ -f "$SNELL_BIN_FILE" ]; then
        echo -e "${Error} Snell Server 似乎已经安装，请勿重复安装（如需升级请选菜单 ${Green}5${Reset}）。"
        return 0
    fi

    echo ""
    echo -e "${Info} [步骤 1/5] 检查并安装系统依赖"
    install_dependencies

    echo ""
    echo -e "${Info} [步骤 2/5] 下载并部署 Snell Server ${Yellow}${VERSION}${Reset}"
    local tmp_dir
    tmp_dir=$(download_snell_to_tmp "$VERSION") || return 1
    echo -e "${Info} 正在安装二进制文件至 ${Yellow}${SNELL_BIN_FILE}${Reset}..."
    mv -f "${tmp_dir}/snell-server" "$SNELL_BIN_FILE"
    rm -rf "$tmp_dir"
    echo -e "${Info} 二进制文件部署完成，已清理临时目录。"

    echo ""
    echo -e "${Info} [步骤 3/5] 交互式配置 Snell Server 参数"
    local snell_remark snell_port snell_psk ipv6_enable snell_ipv6 dual_listen snell_listen snell_mode snell_dns_pref

    read -rp "请输入节点名称备注 [默认: Snell-Server]: " snell_remark
    snell_remark="${snell_remark:-Snell-Server}"

    while true; do
        read -rp "请输入服务端口 [留空随机 20000-65535]: " snell_port
        if [ -z "$snell_port" ]; then
            snell_port=$(generate_random_port)
            echo -e "${Info} 已随机生成端口: ${Green}${snell_port}${Reset}"
            break
        elif validate_port "$snell_port"; then
            echo -e "${Info} 使用指定端口: ${Green}${snell_port}${Reset}"
            break
        else
            echo -e "${Error} 端口无效，请输入 1-65535 之间的数字。"
        fi
    done

    read -rp "请输入 PSK 密钥 [留空自动生成 32 位带符号强密码]: " snell_psk
    if [ -z "$snell_psk" ]; then
        snell_psk=$(generate_strong_psk)
        echo -e "${Info} 已自动生成 32 位强密码 PSK。"
    fi

    read -rp "是否开启 IPv6 出站支持 (ipv6)? [y/N]: " ipv6_enable
    [[ "$ipv6_enable" =~ ^[yY]$ ]] && snell_ipv6="true" || snell_ipv6="false"

    snell_listen="0.0.0.0:${snell_port}"
    read -rp "是否开启双栈入站监听 (同时监听 IPv4 与 IPv6)? [y/N]: " dual_listen
    if [[ "$dual_listen" =~ ^[yY]$ ]]; then
        snell_listen="0.0.0.0:${snell_port},[::]:${snell_port}"
    fi

    snell_mode=$(prompt_mode "default")
    snell_dns_pref=$(prompt_dns_pref "default")

    echo ""
    echo -e "${Info} [步骤 4/5] 写入配置文件并创建 Systemd 服务"
    write_config "$snell_remark" "$snell_listen" "$snell_psk" "$snell_ipv6" "$snell_mode" "$snell_dns_pref"
    write_systemd_service

    echo ""
    echo -e "${Info} [步骤 5/5] 配置开机自启并启动 Snell 服务"
    echo -e "${Info} 正在启用开机自启 (systemctl enable snell)..."
    systemctl enable snell >/dev/null 2>&1
    echo -e "${Info} 正在启动服务 (systemctl start snell)..."
    systemctl start snell
    sleep 1

    if systemctl is-active --quiet snell; then
        echo -e "\n${Green}Snell Server 安装并启动成功!${Reset}"
        view_config_info
    else
        echo -e "${Error} Snell 服务启动失败，请执行 ${Yellow}journalctl -u snell -n 20${Reset} 查看日志。"
    fi
}

update_snell(){
    if [ ! -f "$SNELL_BIN_FILE" ]; then
        echo -e "${Error} 未检测到 Snell Server 安装，无法升级。"
        return 0
    fi

    local old_ver target_ver tmp_dir
    old_ver=$(get_installed_version)

    echo ""
    echo -e "${Info} [步骤 1/5] 确认版本信息"
    echo -e "${Info} 当前安装版本: ${Green}${old_ver}${Reset}"
    echo -ne "请输入目标版本号 [回车默认: ${Yellow}${VERSION}${Reset}]: "
    read -r target_ver
    target_ver="${target_ver:-$VERSION}"

    echo ""
    echo -e "${Info} [步骤 2/5] 检查依赖并下载校验新版本 (${Yellow}${target_ver}${Reset})"
    install_dependencies
    tmp_dir=$(download_snell_to_tmp "$target_ver") || return 1

    echo ""
    echo -e "${Info} [步骤 3/5] 停止服务并替换二进制文件"
    echo -e "${Info} 正在停止 Snell 服务..."
    systemctl stop snell
    echo -e "${Info} 正在备份旧版本至 ${Yellow}${SNELL_BIN_FILE}.bak${Reset}..."
    cp -f "$SNELL_BIN_FILE" "${SNELL_BIN_FILE}.bak"
    echo -e "${Info} 正在部署新版本至 ${Yellow}${SNELL_BIN_FILE}${Reset}..."
    mv -f "${tmp_dir}/snell-server" "$SNELL_BIN_FILE"
    rm -rf "$tmp_dir"

    echo ""
    echo -e "${Info} [步骤 4/5] 检查 Systemd 单元与权限配置"
    if [ -f "$LEGACY_SERVICE_FILE" ] || grep -q "Group=nogroup" "$SNELL_SERVICE_FILE" 2>/dev/null; then
        echo -e "${Info} 检测到旧版 Systemd 配置，正在迁移至最小权限服务单元..."
        ensure_snell_user
        if [ -d "$SNELL_CONFIG_DIR" ]; then
            chown -R root:"$SNELL_USER" "$SNELL_CONFIG_DIR"
            chmod 750 "$SNELL_CONFIG_DIR"
        fi
        [ -f "$SNELL_CONFIG_FILE" ] && chmod 640 "$SNELL_CONFIG_FILE"
        write_systemd_service
    else
        echo -e "${Info} Systemd 配置无需迁移，正在重载配置..."
        systemctl daemon-reload
    fi

    echo ""
    echo -e "${Info} [步骤 5/5] 启动新版本并验证服务状态"
    echo -e "${Info} 正在启动 Snell 服务..."
    systemctl start snell
    sleep 1

    if systemctl is-active --quiet snell; then
        echo -e "${Info} 服务启动正常，正在清理旧版本备份文件..."
        rm -f "${SNELL_BIN_FILE}.bak"
        local new_ver
        new_ver=$(get_installed_version)
        echo -e "\n${Green}升级成功! 当前运行版本: ${new_ver}${Reset}"
        echo -e "${Warn} 如从 v5 升级至 v6：客户端需同步升级并设为 ${Yellow}version=6${Reset}；v6 已移除 QUIC Proxy Mode，防火墙可关闭对应 UDP 端口。"
    else
        echo -e "${Error} 新版本启动失败，正在执行回滚流程..."
        echo -e "${Info} 正在恢复旧版本二进制文件 (${old_ver})..."
        mv -f "${SNELL_BIN_FILE}.bak" "$SNELL_BIN_FILE"
        echo -e "${Info} 正在重新启动旧版本服务..."
        systemctl start snell
        if systemctl is-active --quiet snell; then
            echo -e "${Info} 已成功回滚至旧版本并恢复运行。"
        else
            echo -e "${Error} 回滚后仍启动失败，请执行 ${Yellow}journalctl -u snell -n 20${Reset} 检查日志。"
        fi
    fi
}

uninstall_snell(){
    if [ ! -f "$SNELL_BIN_FILE" ] && [ ! -f "$SNELL_CONFIG_FILE" ] && [ ! -f "$SNELL_SERVICE_FILE" ]; then
        echo -e "${Error} 未检测到 Snell Server 安装，无需卸载。"
        return 0
    fi

    local confirm
    echo ""
    echo -ne "${Red}确定要彻底卸载 Snell Server 及所有配置文件吗? [y/N]: ${Reset}"
    read -r confirm
    [[ ! "$confirm" =~ ^[yY]$ ]] && echo -e "${Info} 已取消卸载。" && return 0

    echo ""
    echo -e "${Info} [步骤 1/5] 停止服务并取消开机自启"
    if systemctl is-active --quiet snell 2>/dev/null; then
        echo -e "${Info} 正在停止 Snell 服务..."
        systemctl stop snell || true
    else
        echo -e "${Info} Snell 服务当前未运行，跳过停止步骤。"
    fi

    if systemctl is-enabled --quiet snell 2>/dev/null; then
        echo -e "${Info} 正在取消开机自启..."
        systemctl disable snell >/dev/null 2>&1 || true
    fi

    echo ""
    echo -e "${Info} [步骤 2/5] 删除 Systemd 服务文件"
    for svc in "$SNELL_SERVICE_FILE" "$LEGACY_SERVICE_FILE"; do
        if [ -f "$svc" ]; then
            echo -e "${Info} 删除服务文件: ${Yellow}${svc}${Reset}"
            rm -f "$svc"
        fi
    done
    echo -e "${Info} 重载 Systemd 配置 (systemctl daemon-reload)..."
    systemctl daemon-reload

    echo ""
    echo -e "${Info} [步骤 3/5] 删除二进制文件与备份"
    for bin in "$SNELL_BIN_FILE" "${SNELL_BIN_FILE}.bak"; do
        if [ -f "$bin" ]; then
            echo -e "${Info} 删除文件: ${Yellow}${bin}${Reset}"
            rm -f "$bin"
        fi
    done

    echo ""
    echo -e "${Info} [步骤 4/5] 删除配置目录"
    if [ -d "$SNELL_CONFIG_DIR" ]; then
        echo -e "${Info} 删除配置目录: ${Yellow}${SNELL_CONFIG_DIR}${Reset}"
        rm -rf "$SNELL_CONFIG_DIR"
    fi

    echo ""
    echo -e "${Info} [步骤 5/5] 清理专用系统用户"
    if id -u "$SNELL_USER" >/dev/null 2>&1; then
        echo -e "${Info} 删除系统用户: ${Yellow}${SNELL_USER}${Reset}"
        userdel "$SNELL_USER" 2>/dev/null || true
    else
        echo -e "${Info} 未检测到专用用户 ${SNELL_USER}，跳过清理。"
    fi

    echo -e "\n${Green}Snell Server 已彻底卸载完成！${Reset}"
}

view_config_info(){
    if [ ! -f "$SNELL_CONFIG_FILE" ]; then
        echo -e "${Error} Snell 配置文件不存在，可能未安装。"
        return 0
    fi

    local remark listen port psk ipv6 mode dns_pref current_ver ver_num public_ip node_line status_text
    remark=$(read_conf_remark)
    listen=$(read_conf_val "listen")
    port=$(echo "$listen" | cut -d',' -f1 | awk -F':' '{print $NF}')
    psk=$(read_conf_val "psk")
    ipv6=$(read_conf_val "ipv6" "false")
    mode=$(read_conf_val "mode" "default")
    dns_pref=$(read_conf_val "dns-ip-preference" "default")

    current_ver=$(get_installed_version)
    ver_num=$(echo "$current_ver" | grep -oE 'v[0-9]+' | tr -d 'v' || true)
    ver_num="${ver_num:-6}"

    public_ip=$(get_public_ip)
    status_text=$(get_service_status_text)

    echo ""
    echo "-------------- Snell 配置信息 --------------"
    echo -e "  运行状态:   ${status_text}"
    echo -e "  当前版本:   ${Green}${current_ver}${Reset}"
    echo -e "  节点名称:   ${remark}"
    echo -e "  服务器 IP:  ${Yellow}${public_ip}${Reset}"
    echo -e "  监听地址:   ${listen}"
    echo -e "  服务端口:   ${Yellow}${port}${Reset}"
    echo -e "  连接密钥:   ${Yellow}${psk}${Reset}"
    echo -e "  传输模式:   ${Green}${mode}${Reset}"
    echo -e "  IPv6 出站:  ${ipv6}"
    echo -e "  DNS 偏好:   ${dns_pref}"
    echo "--------------------------------------------"

    node_line="${remark} = snell, ${public_ip}, ${port}, psk=${psk}, version=${ver_num}, reuse=true"
    if [ "$mode" != "default" ]; then
        node_line="${node_line}, mode=${mode}"
    fi

    echo ""
    echo "---------- Surge / Egern 节点配置 ----------"
    echo -e "${Green}${node_line}${Reset}"
    echo "--------------------------------------------"

    if [ "$mode" = "unsafe-raw" ]; then
        echo -e "${Warn} 当前为 ${Red}unsafe-raw${Reset} 明文模式，请确保仅用于内网或套在加密隧道内落地。"
    fi
}

modify_config(){
    if [ ! -f "$SNELL_CONFIG_FILE" ]; then
        echo -e "${Error} Snell 配置文件不存在，请先安装。"
        return 0
    fi

    echo ""
    echo -e "${Info} [步骤 1/4] 读取当前配置 (${Yellow}${SNELL_CONFIG_FILE}${Reset})"
    local cur_remark cur_listen cur_port cur_dual cur_psk cur_ipv6 cur_mode cur_dns_pref
    cur_remark=$(read_conf_remark)
    cur_listen=$(read_conf_val "listen")
    cur_port=$(echo "$cur_listen" | cut -d',' -f1 | awk -F':' '{print $NF}')
    [[ "$cur_listen" == *"[::]:"* ]] && cur_dual="y" || cur_dual="n"
    cur_psk=$(read_conf_val "psk")
    cur_ipv6=$(read_conf_val "ipv6" "false")
    cur_mode=$(read_conf_val "mode" "default")
    cur_dns_pref=$(read_conf_val "dns-ip-preference" "default")

    echo ""
    echo -e "${Info} [步骤 2/4] 交互式修改参数（直接回车保留当前值）"
    local new_remark port_input new_port psk_input new_psk ipv6_input new_ipv6 dual_input new_dual new_listen new_mode new_dns_pref

    echo -ne "节点名称 [当前: ${Yellow}${cur_remark}${Reset}]: "
    read -r new_remark
    new_remark="${new_remark:-$cur_remark}"

    while true; do
        echo -ne "服务端口 [当前: ${Yellow}${cur_port}${Reset}，输入 rand 随机]: "
        read -r port_input
        if [ -z "$port_input" ]; then
            new_port="$cur_port"
            break
        elif [[ "${port_input,,}" == "rand" ]]; then
            new_port=$(generate_random_port)
            echo -e "${Info} 已随机生成新端口: ${Green}${new_port}${Reset}"
            break
        elif validate_port "$port_input"; then
            new_port="$port_input"
            echo -e "${Info} 端口将更新为: ${Green}${new_port}${Reset}"
            break
        else
            echo -e "${Error} 端口无效，请输入 1-65535 之间的数字。"
        fi
    done

    echo -ne "PSK 密钥 [当前: ${Yellow}${cur_psk}${Reset}，输入 rand 重新生成]: "
    read -r psk_input
    if [ -z "$psk_input" ]; then
        new_psk="$cur_psk"
    elif [[ "${psk_input,,}" == "rand" ]]; then
        new_psk=$(generate_strong_psk)
        echo -e "${Info} 已生成新的 32 位强密码 PSK。"
    else
        new_psk="$psk_input"
    fi

    echo -ne "是否开启 IPv6 出站支持 (ipv6)? [当前: ${Yellow}${cur_ipv6}${Reset}] (y/n): "
    read -r ipv6_input
    new_ipv6="$cur_ipv6"
    [[ "$ipv6_input" =~ ^[yY]$ ]] && new_ipv6="true"
    [[ "$ipv6_input" =~ ^[nN]$ ]] && new_ipv6="false"

    echo -ne "是否开启双栈入站监听 (IPv4+IPv6)? [当前: ${Yellow}${cur_dual}${Reset}] (y/n): "
    read -r dual_input
    new_dual="$cur_dual"
    [[ "$dual_input" =~ ^[yY]$ ]] && new_dual="y"
    [[ "$dual_input" =~ ^[nN]$ ]] && new_dual="n"

    new_listen="0.0.0.0:${new_port}"
    [ "$new_dual" = "y" ] && new_listen="0.0.0.0:${new_port},[::]:${new_port}"

    new_mode=$(prompt_mode "$cur_mode")
    new_dns_pref=$(prompt_dns_pref "$cur_dns_pref")

    echo ""
    echo -e "${Info} [步骤 3/4] 写入更新后的配置文件"
    write_config "$new_remark" "$new_listen" "$new_psk" "$new_ipv6" "$new_mode" "$new_dns_pref"

    echo ""
    echo -e "${Info} [步骤 4/4] 重启 Snell 服务并验证状态"
    echo -e "${Info} 正在重启服务 (systemctl restart snell)..."
    systemctl restart snell
    sleep 1

    if systemctl is-active --quiet snell; then
        echo -e "\n${Green}Snell 服务重启成功，新配置已生效!${Reset}"
        view_config_info
    else
        echo -e "${Error} Snell 服务重启失败，请执行 ${Yellow}journalctl -u snell -n 20${Reset} 检查错误。"
    fi
}

view_logs(){
    echo ""
    echo "-------------- Snell 最近 30 条日志 --------------"
    journalctl -u snell -n 30 --no-pager
    echo "--------------------------------------------------"
}

# --- 主菜单 ---

main_menu(){
    while true; do
        local local_ver status_text user_choice
        local_ver=$(get_installed_version)
        status_text=$(get_service_status_text)

        echo ""
        echo "================================================"
        echo -e "  ${Green}Snell Server 一键管理脚本${Reset} (v6 适配版)"
        echo -e "  目标版本: ${Yellow}${VERSION}${Reset} | 当前: ${Yellow}${local_ver}${Reset} | 状态: ${status_text}"
        echo "================================================"
        echo ""
        echo -e "  ${Green}1.${Reset} 安装 Snell Server"
        echo -e "  ${Green}2.${Reset} 卸载 Snell Server"
        echo -e "  ${Green}3.${Reset} 查看 Snell 配置"
        echo -e "  ${Green}4.${Reset} 修改 Snell 配置"
        echo -e "  ${Green}5.${Reset} 升级 Snell Server"
        echo -e "  ${Green}6.${Reset} 查看运行日志"
        echo ""
        echo -e "  ${Yellow}0.${Reset} 退出脚本"
        echo ""
        echo "================================================"
        read -rp "请输入您的选择 [0-6]: " user_choice

        case "$user_choice" in
            1) install_snell ;;
            2) uninstall_snell ;;
            3) view_config_info ;;
            4) modify_config ;;
            5) update_snell ;;
            6) view_logs ;;
            0) exit 0 ;;
            *)
                echo -e "${Error} 无效的输入，请输入 0-6。"
                sleep 1
                continue
                ;;
        esac

        echo ""
        read -n1 -r -p "按任意键返回主菜单..."
        echo ""
    done
}

check_root
main_menu
