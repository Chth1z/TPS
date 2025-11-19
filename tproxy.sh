#!/system/bin/sh

# 配置项（按需修改）

# 代理软件配置
# 代理运行用户与用户组
CORE_USER_GROUP="root:net_admin"
# 代理流量标记
ROUTING_MARK="6666"
# 代理端口 (透明代理程序监听端口)
PROXY_TCP_PORT="1536"
PROXY_UDP_PORT="1536"

# DNS 配置
# DNS 拦截方式 (0:关闭, 1:tproxy, 2:redirect)
DNS_HIJACK_ENABLE=1
# DNS 监听端口
DNS_PORT="1053"

# 接口定义
# 数据 接口
MOBILE_INTERFACE="rmnet_data+"
# WiFi 接口
WIFI_INTERFACE="wlan0"
# 热点 接口
HOTSPOT_INTERFACE="wlan2"
# USB 共享接口
USB_INTERFACE="rndis+"

# 代理开关
PROXY_MOBILE=1
PROXY_WIFI=1
PROXY_HOTSPOT=0
PROXY_USB=0
PROXY_TCP=1
PROXY_UDP=1
PROXY_IPV6=0

# mark 值
MARK_VALUE=20
MARK_VALUE6=25

# 路由表 id
TABLE_ID=2025

# 分应用代理（使用空格分隔包名并支持 user:package）
APP_PROXY_ENABLE=1
PROXY_APPS_LIST=""
# 示例: "com.example.app com.other"
BYPASS_APPS_LIST=""
# 示例: "com.android.shell"
APP_PROXY_MODE="blacklist"
# "blacklist" 或 "whitelist"

# CN IP 绕过配置
BYPASS_CN_IP=0
# CN IP 列表文件路径（相对路径为脚本所在目录）
CN_IP_FILE="cn.zone"
CN_IPV6_FILE="cn_ipv6.zone"
# CN IP 源 URL
CN_IP_URL="https://raw.githubusercontent.com/Hackl0us/GeoIP2-CN/release/CN-ip-cidr.txt"
CN_IPV6_URL="https://ispip.clang.cn/all_cn_ipv6.txt"

# MAC 地址黑白名单配置（热点模式）
MAC_FILTER_ENABLE=0
# MAC 地址黑白名单列表（使用空格分隔MAC地址）
PROXY_MACS_LIST=""
# 示例: "AA:BB:CC:DD:EE:FF 11:22:33:44:55:66"
BYPASS_MACS_LIST=""
# 示例: "FF:EE:DD:CC:BB:AA"
MAC_PROXY_MODE="blacklist"
# "blacklist" 或 "whitelist"

# Dry-run 模式（默认关闭）
DRY_RUN=0

# 日志函数
log() {
    level="$1"
    message="$2"
    timestamp="$(date +"%Y-%m-%d %H:%M:%S")"
    color_code="\033[0m"

    case $level in
        Debug) color_code="\033[0;36m" ;;
        Info) color_code="\033[1;32m" ;;
        Warn) color_code="\033[1;33m" ;;
        Error) color_code="\033[1;31m" ;;
    esac

    [ -t 1 ] \
        && echo -e "${color_code}${timestamp} [${level}]: ${message}\033[0m" \
        || echo "${timestamp} [${level}]: ${message}"
}

# 检查依赖
check_dependencies() {
    missing=()
    required_commands=(ip iptables curl)

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" > /dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log Error "Missing required commands: ${missing[*]}"
        log Info "Check PATH: $PATH"
        exit 1
    fi

    # 验证 busybox 必要小工具
    # required_applets=(awk cut grep pidof stat)
    # for applet in "${required_applets[@]}"; do
    #  if ! busybox --list | grep -q "^${applet}\$"; then
    #    log Error "busybox missing applet: $applet"
    #    exit 1
    #  fi
    # done
}

# 检查内核功能
check_kernel_feature() {
    feature="$1"
    config_name="CONFIG_${feature}"

    if [ -f /proc/config.gz ]; then
        zcat /proc/config.gz | grep -qE "^${config_name}=[ym]$"
    else
        # 备用方法：检查模块是否加载（仅检测模块，内置功能需其他方法比如检查 dmesg）
        # lsmod | grep -q "$feature" || return 1
        return 1
    fi
}

# 检查是否支持TPROXY
check_tproxy_support() {
    if check_kernel_feature "NETFILTER_XT_TARGET_TPROXY"; then
        return 0
    else
        return 1
    fi
}

# 用户与组解析
validate_user_group() {
    IFS=':' read -r CORE_USER CORE_GROUP <<< "$CORE_USER_GROUP"
    [ -z "$CORE_USER" ] || [ -z "$CORE_GROUP" ] && {
        CORE_USER="root"
        CORE_GROUP="net_admin"
    }
}

# 命令执行函数（支持 dry-run）
execute() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log Debug "[DRY-RUN] $*"
    else
        log Debug "[EXEC] $*"
        "$@"
    fi
}

# 重新定义命令以支持 Dry-run 模式
iptables() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log Debug "[DRY-RUN] iptables $*"
    else
        command iptables -w 100 "$@"
    fi
}

ip_rule() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log Debug "[DRY-RUN] ip rule $*"
    else
        command ip rule "$@"
    fi
}

ip_route() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log Debug "[DRY-RUN] ip route $*"
    else
        command ip route "$@"
    fi
}

ip6tables() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log Debug "[DRY-RUN] ip6tables $*"
    else
        command ip6tables -w 100 "$@"
    fi
}

ip6_rule() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log Debug "[DRY-RUN] ip -6 rule $*"
    else
        command ip -6 rule "$@"
    fi
}

ip6_route() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log Debug "[DRY-RUN] ip -6 route $*"
    else
        command ip -6 route "$@"
    fi
}

get_package_uid() {
    pkg="$1"
    if [ ! -r /data/system/packages.list ]; then
        return 1
    fi
    line=$(grep -m1 "^${pkg}[[:space:]]" /data/system/packages.list 2> /dev/null || true)
    if [ -z "$line" ]; then
        return 1
    fi
    uid=$(printf "%s\n" "$line" | awk '{print $2}' 2> /dev/null || true)
    case "$uid" in
        '' | *[!0-9]*)
            uid=$(printf "%s\n" "$line" | awk '{print $(NF-1)}' 2> /dev/null || true)
            ;;
    esac
    case "$uid" in
        '' | *[!0-9]*)
            return 1
            ;;
        *)
            printf "%s" "$uid"
            return 0
            ;;
    esac
}

find_packages_uid() {
    out=""
    for token in $*; do
        user_prefix=0
        package="$token"
        case "$token" in
            *:*)
                user_prefix=$(printf "%s\n" "$token" | cut -d: -f1)
                package=$(printf "%s\n" "$token" | cut -d: -f2-)
                case "$user_prefix" in
                    '' | *[!0-9]*) user_prefix=0 ;;
                esac
                ;;
        esac
        if uid_base=$(get_package_uid "$package" 2> /dev/null || true); then
            final_uid=$((user_prefix * 100000 + uid_base))
            out="$out $final_uid"
        fi
    done
    printf "%s" "$(echo "$out" | awk '{$1=$1;print}')"
}

safe_chain_exists() {
    table="$1"
    chain="$2"
    if [ "$DRY_RUN" -eq 1 ]; then
        log Debug "[DRY-RUN] Check if chain $chain exists in table $table"
        return 1
    fi
    if iptables -t "$table" -L "$chain" > /dev/null 2>&1; then
        log Debug "Chain $chain exists in table $table"
        return 0
    fi
    log Debug "Chain $chain does not exist in table $table"
    return 1
}

safe_chain_create() {
    table="$1"
    chain="$2"
    if ! safe_chain_exists "$table" "$chain"; then
        log Debug "Creating chain $chain in table $table"
        iptables -t "$table" -N "$chain"
    fi
    iptables -t "$table" -F "$chain"
}

safe_chain_exists6() {
    table="$1"
    chain="$2"
    if [ "$DRY_RUN" -eq 1 ]; then
        log Debug "[DRY-RUN] Check if IPv6 chain $chain exists in table $table"
        return 1
    fi
    if ip6tables -t "$table" -L "$chain" > /dev/null 2>&1; then
        log Debug "IPv6 chain $chain exists in table $table"
        return 0
    fi
    log Debug "IPv6 chain $chain does not exist in table $table"
    return 1
}

safe_chain_create6() {
    table="$1"
    chain="$2"
    if ! safe_chain_exists6 "$table" "$chain"; then
        log Debug "Creating IPv6 chain $chain in table $table"
        ip6tables -t "$table" -N "$chain"
    fi
    ip6tables -t "$table" -F "$chain"
}

# 下载中国大陆 IP 列表（使用 curl）
download_cn_ip_list() {
    if [ "$BYPASS_CN_IP" -eq 0 ]; then
        log Debug "CN IP bypass is disabled, skipping download"
        return 0
    fi

    log Info "Checking/Downloading China mainland IP list to $CN_IP_FILE"

    # 如果文件不存在或超过7天，则重新下载
    if [ ! -f "$CN_IP_FILE" ] || [ "$(find "$CN_IP_FILE" -mtime +7 2>/dev/null)" ]; then
        log Debug "Fetching latest China IP list from $CN_IP_URL..."
        if [ "$DRY_RUN" -eq 1 ]; then
            log Debug "[DRY-RUN] curl -fsSL --connect-timeout 10 --retry 3 $CN_IP_URL -o $CN_IP_FILE.tmp"
        else
            if ! curl -fsSL --connect-timeout 10 --retry 3 \
                "$CN_IP_URL" \
                -o "$CN_IP_FILE.tmp"; then
                log Error "Failed to download China IP list"
                rm -f "$CN_IP_FILE.tmp"
                return 1
            fi
        fi
        if [ "$DRY_RUN" -eq 0 ]; then
            mv "$CN_IP_FILE.tmp" "$CN_IP_FILE"
        fi
        log Info "China IP list saved to $CN_IP_FILE"
    else
        log Debug "Using existing China IP list: $CN_IP_FILE"
    fi

    # 下载 IPv6
    if [ "$PROXY_IPV6" -eq 1 ]; then
        log Info "Checking/Downloading China mainland IPv6 list to $CN_IPV6_FILE"

        if [ ! -f "$CN_IPV6_FILE" ] || [ "$(find "$CN_IPV6_FILE" -mtime +7 2>/dev/null)" ]; then
            log Debug "Fetching latest China IPv6 list from $CN_IPV6_URL..."
            if [ "$DRY_RUN" -eq 1 ]; then
                log Debug "[DRY-RUN] curl -fsSL --connect-timeout 10 --retry 3 $CN_IPV6_URL -o $CN_IPV6_FILE.tmp"
            else
                if ! curl -fsSL --connect-timeout 10 --retry 3 \
                    "$CN_IPV6_URL" \
                    -o "$CN_IPV6_FILE.tmp"; then
                    log Error "Failed to download China IPv6 list"
                    rm -f "$CN_IPV6_FILE.tmp"
                    return 1
                fi
            fi
            if [ "$DRY_RUN" -eq 0 ]; then
                mv "$CN_IPV6_FILE.tmp" "$CN_IPV6_FILE"
            fi
            log Info "China IPv6 list saved to $CN_IPV6_FILE"
        else
            log Debug "Using existing China IPv6 list: $CN_IPV6_FILE"
        fi
    fi
}

# 创建 ipset 集合（用于 BYPASS_IP 规则）
setup_cn_ipset() {
    if [ "$BYPASS_CN_IP" -eq 0 ]; then
        log Debug "CN IP bypass is disabled, skipping ipset setup"
        return 0
    fi

    if ! command -v ipset > /dev/null 2>&1; then
        log Error "ipset not found. Cannot bypass CN IPs."
        return 1
    fi

    log Info "Setting up ipset for China mainland IPs"

    # 删除旧集合（忽略错误）
    if [ "$DRY_RUN" -eq 1 ]; then
        log Debug "[DRY-RUN] ipset destroy cnip"
        log Debug "[DRY-RUN] ipset destroy cnip6"
    else
        ipset destroy cnip 2>/dev/null || true
        ipset destroy cnip6 2>/dev/null || true
    fi

    # 创建 IPv4 hash:net 类型的 ipset
    if [ "$DRY_RUN" -eq 1 ]; then
        log Debug "[DRY-RUN] ipset create cnip hash:net family inet hashsize 8192 maxelem 65536"
    else
        if ! ipset create cnip hash:net family inet hashsize 8192 maxelem 65536; then
            log Error "Failed to create ipset 'cnip'"
            return 1
        fi
    fi

    # 批量添加 IPv4 CIDR
    if [ -f "$CN_IP_FILE" ]; then
        log Debug "Loading IPv4 CIDR from $CN_IP_FILE"
        while IFS= read -r cidr; do
            # 跳过空行和注释
            case "$cidr" in
                '' | \#*) continue ;;
            esac
            # 验证是否为合法 IPv4 CIDR
            if echo "$cidr" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$'; then
                if [ "$DRY_RUN" -eq 1 ]; then
                    log Debug "[DRY-RUN] ipset add cnip $cidr"
                else
                    ipset add cnip "$cidr" 2>/dev/null || true
                fi
            fi
        done < "$CN_IP_FILE"
    fi

    log Info "ipset 'cnip' loaded with China mainland IPs"

    # 创建 IPv6 hash:net 类型的 ipset
    if [ "$PROXY_IPV6" -eq 1 ] && [ -f "$CN_IPV6_FILE" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            log Debug "[DRY-RUN] ipset create cnip6 hash:net family inet6 hashsize 4096 maxelem 8192"
        else
            if ! ipset create cnip6 hash:net family inet6 hashsize 4096 maxelem 8192; then
                log Error "Failed to create ipset 'cnip6'"
                return 1
            fi
        fi

        # 批量添加 IPv6 CIDR
        if [ -f "$CN_IPV6_FILE" ]; then
            log Debug "Loading IPv6 CIDR from $CN_IPV6_FILE"
            while IFS= read -r cidr; do
                # 跳过空行和注释
                case "$cidr" in
                    '' | \#*) continue ;;
                esac
                # 验证是否为合法 IPv6 CIDR
                if echo "$cidr" | grep -qE '^([0-9a-fA-F:]+:+[0-9a-fA-F]*)/[0-9]+$'; then
                    if [ "$DRY_RUN" -eq 1 ]; then
                        log Debug "[DRY-RUN] ipset add cnip6 $cidr"
                    else
                        ipset add cnip6 "$cidr" 2>/dev/null || true
                    fi
                fi
            done < "$CN_IPV6_FILE"
        fi

        log Info "ipset 'cnip6' loaded with China mainland IPv6 IPs"
    fi
}

setup_tproxy_chain4() {
    log Info "Setting up TPROXY chains for IPv4"

    for c in PROXY_PREROUTING PROXY_OUTPUT BYPASS_IP BYPASS_INTERFACE PROXY_INTERFACE DNS_HIJACK_PRE DNS_HIJACK_OUT APP_CHAIN MAC_CHAIN; do
        safe_chain_create mangle "$c"
    done

    if [ "${PROXY_TCP:-1}" -eq 1 ]; then
        iptables -t mangle -I PREROUTING -p tcp -j PROXY_PREROUTING
        iptables -t mangle -I OUTPUT -p tcp -j PROXY_OUTPUT
        log Debug "Added TCP rules to PREROUTING and OUTPUT chains"
    fi
    if [ "${PROXY_UDP:-1}" -eq 1 ]; then
        iptables -t mangle -I PREROUTING -p udp -j PROXY_PREROUTING
        iptables -t mangle -I OUTPUT -p udp -j PROXY_OUTPUT
        log Debug "Added UDP rules to PREROUTING and OUTPUT chains"
    fi

    iptables -t mangle -A PROXY_PREROUTING -j BYPASS_IP
    iptables -t mangle -A PROXY_PREROUTING -j PROXY_INTERFACE
    iptables -t mangle -A PROXY_PREROUTING -j MAC_CHAIN
    iptables -t mangle -A PROXY_PREROUTING -j DNS_HIJACK_PRE

    iptables -t mangle -A PROXY_OUTPUT -j BYPASS_IP
    iptables -t mangle -A PROXY_OUTPUT -j BYPASS_INTERFACE
    iptables -t mangle -A PROXY_OUTPUT -j APP_CHAIN
    iptables -t mangle -A PROXY_OUTPUT -j DNS_HIJACK_OUT

    # 内网地址绕过
    if check_kernel_feature "NETFILTER_XT_MATCH_ADDRTYPE"; then
        iptables -t mangle -A BYPASS_IP -m addrtype --dst-type LOCAL -j RETURN
        log Debug "Added local address type bypass"
    fi
    for subnet4 in 0.0.0.0/8 10.0.0.0/8 100.0.0.0/8 127.0.0.0/8 \
        169.254.0.0/16 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 \
        192.168.0.0/16 198.51.100.0/24 203.0.113.0/24 \
        224.0.0.0/4 240.0.0.0/4 255.255.255.255/32; do
        iptables -t mangle -A BYPASS_IP -d "$subnet4" -p udp ! --dport 53 -j ACCEPT
        iptables -t mangle -A BYPASS_IP -d "$subnet4" ! -p udp -j ACCEPT
    done
    log Debug "Added bypass rules for private IP ranges"

    # 绕过中国大陆 IP（如果启用）
    if [ "$BYPASS_CN_IP" -eq 1 ]; then
        if command -v ipset > /dev/null 2>&1 && ipset list cnip > /dev/null 2>&1; then
            iptables -t mangle -A BYPASS_IP -m set --match-set cnip dst -j ACCEPT
            log Debug "Added ipset-based CN IP bypass rule"
        else
            log Warn "ipset 'cnip' not available, skipping CN IP bypass"
        fi
    fi

    # 处理接口
    iptables -t mangle -A PROXY_INTERFACE -i lo -j RETURN
    log Debug "Added loopback interface bypass rule"
    if [ "${PROXY_MOBILE:-1}" -eq 1 ]; then
        iptables -t mangle -A PROXY_INTERFACE -i "$MOBILE_INTERFACE" -j RETURN
        log Debug "Mobile interface $MOBILE_INTERFACE will be proxied"
    else
        iptables -t mangle -A PROXY_INTERFACE -i "$MOBILE_INTERFACE" -j ACCEPT
        iptables -t mangle -A BYPASS_INTERFACE -o "$MOBILE_INTERFACE" -j ACCEPT
        log Debug "Mobile interface $MOBILE_INTERFACE will bypass proxy"
    fi
    if [ "${PROXY_WIFI:-1}" -eq 1 ]; then
        iptables -t mangle -A PROXY_INTERFACE -i "$WIFI_INTERFACE" -j RETURN
        log Debug "WiFi interface $WIFI_INTERFACE will be proxied"
    else
        iptables -t mangle -A PROXY_INTERFACE -i "$WIFI_INTERFACE" -j ACCEPT
        iptables -t mangle -A BYPASS_INTERFACE -o "$WIFI_INTERFACE" -j ACCEPT
        log Debug "WiFi interface $WIFI_INTERFACE will bypass proxy"
    fi
    if [ "${PROXY_HOTSPOT:-0}" -eq 1 ]; then
        if [ "$HOTSPOT_INTERFACE" = "$WIFI_INTERFACE" ]; then
            iptables -t mangle -A PROXY_INTERFACE -i "$WIFI_INTERFACE" ! -s 192.168.43.0/24 -j RETURN
            log Debug "Hotspot interface $WIFI_INTERFACE will be proxied"
        else
            iptables -t mangle -A PROXY_INTERFACE -i "$HOTSPOT_INTERFACE" -j RETURN
            log Debug "Hotspot interface $HOTSPOT_INTERFACE will be proxied"
        fi
    else
        iptables -t mangle -A BYPASS_INTERFACE -o "$HOTSPOT_INTERFACE" -j ACCEPT
        log Debug "Hotspot interface $HOTSPOT_INTERFACE will bypass proxy"
    fi
    if [ "${PROXY_USB:-0}" -eq 1 ]; then
        iptables -t mangle -A PROXY_INTERFACE -i "$USB_INTERFACE" -j RETURN
        log Debug "USB interface $USB_INTERFACE will be proxied"
    else
        iptables -t mangle -A PROXY_INTERFACE -i "$USB_INTERFACE" -j ACCEPT
        iptables -t mangle -A BYPASS_INTERFACE -o "$USB_INTERFACE" -j ACCEPT
        log Debug "USB interface $USB_INTERFACE will bypass proxy"
    fi
    iptables -t mangle -A PROXY_INTERFACE -j ACCEPT
    log Debug "Default proxy interface rule added"

    # 处理 MAC 地址黑白名单（热点模式）
    if [ "$MAC_FILTER_ENABLE" -eq 1 ] && [ -n "$HOTSPOT_INTERFACE" ]; then
        log Debug "Setting up MAC address filter rules for interface $HOTSPOT_INTERFACE"
        case "$MAC_PROXY_MODE" in
            blacklist)
                if [ -n "$BYPASS_MACS_LIST" ]; then
                    for mac in $BYPASS_MACS_LIST; do
                        [ -n "$mac" ] && {
                            iptables -t mangle -A MAC_CHAIN -m mac --mac-source "$mac" -i "$HOTSPOT_INTERFACE" -j ACCEPT
                            log Debug "Added MAC bypass rule for $mac"
                        }
                    done
                fi
                iptables -t mangle -A MAC_CHAIN -i "$HOTSPOT_INTERFACE" -j RETURN
                ;;
            whitelist)
                if [ -n "$PROXY_MACS_LIST" ]; then
                    for mac in $PROXY_MACS_LIST; do
                        [ -n "$mac" ] && {
                            iptables -t mangle -A MAC_CHAIN -m mac --mac-source "$mac" -i "$HOTSPOT_INTERFACE" -j RETURN
                            log Debug "Added MAC proxy rule for $mac"
                        }
                    done
                fi
                iptables -t mangle -A MAC_CHAIN -i "$HOTSPOT_INTERFACE" -j ACCEPT
                ;;
        esac
    fi

    # 绕过本机代理程序自身
    if check_kernel_feature "NETFILTER_XT_MATCH_OWNER"; then
        iptables -t mangle -A APP_CHAIN -m owner --uid-owner "$CORE_USER" --gid-owner "$CORE_GROUP" -j ACCEPT
        log Debug "Added bypass for core user $CORE_USER:$CORE_GROUP"
    elif check_kernel_feature "NETFILTER_XT_MATCH_MARK"; then
        iptables -t mangle -A APP_CHAIN -m mark --mark "$ROUTING_MARK" -j ACCEPT
        log Debug "Added bypass for marked traffic with mark $ROUTING_MARK"
    fi
    # 处理黑白名单
    if [ "${APP_PROXY_ENABLE:-0}" -eq 1 ] && check_kernel_feature "NETFILTER_XT_MATCH_OWNER"; then
        # 根据模式填充
        case "$APP_PROXY_MODE" in
            blacklist)
                if [ -n "$BYPASS_APPS_LIST" ]; then
                    uids=$(find_packages_uid "$BYPASS_APPS_LIST" || true)
                    for uid in $uids; do
                        [ -n "$uid" ] && {
                            iptables -t mangle -A APP_CHAIN -m owner --uid-owner "$uid" -j ACCEPT
                            log Debug "Added bypass for UID $uid"
                        }
                    done
                fi
                iptables -t mangle -A APP_CHAIN -j RETURN
                ;;
            whitelist)
                if [ -n "$PROXY_APPS_LIST" ]; then
                    uids=$(find_packages_uid "$PROXY_APPS_LIST" || true)
                    for uid in $uids; do
                        [ -n "$uid" ] && {
                            iptables -t mangle -A APP_CHAIN -m owner --uid-owner "$uid" -j RETURN
                            log Debug "Added proxy for UID $uid"
                        }
                    done
                fi
                iptables -t mangle -A APP_CHAIN -j ACCEPT
                ;;
        esac
    fi

    # DNS 劫持
    case "${DNS_HIJACK_ENABLE:-1}" in
        1)
            # DNS_HIJACK_PRE 处理来自接口的 DNS （PREROUTING）
            iptables -t mangle -A DNS_HIJACK_PRE -p tcp --dport 53 -j TPROXY --on-port "$PROXY_TCP_PORT" --tproxy-mark "$MARK_VALUE"
            iptables -t mangle -A DNS_HIJACK_PRE -p udp --dport 53 -j TPROXY --on-port "$PROXY_UDP_PORT" --tproxy-mark "$MARK_VALUE"
            # DNS_HIJACK_OUT 用于 OUTPUT 的本地 DNS 劫持
            iptables -t mangle -A DNS_HIJACK_OUT -p tcp --dport 53 -j MARK --set-mark "$MARK_VALUE"
            iptables -t mangle -A DNS_HIJACK_OUT -p udp --dport 53 -j MARK --set-mark "$MARK_VALUE"
            log Debug "DNS hijack enabled using TPROXY mode"
            ;;
        2)
            # 非 TPROXY 方式接收 DNS 流量
            safe_chain_create nat "NAT_DNS_HIJACK"
            iptables -t nat -A NAT_DNS_HIJACK -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
            log Debug "DNS hijack enabled using REDIRECT mode to port $DNS_PORT"

            [ "${PROXY_MOBILE:-1}" -eq 1 ] && iptables -t nat -A PREROUTING -i "$MOBILE_INTERFACE" -j NAT_DNS_HIJACK
            [ "${PROXY_WIFI:-1}" -eq 1 ] && iptables -t nat -A PREROUTING -i "$WIFI_INTERFACE" -j NAT_DNS_HIJACK

            iptables -t nat -A OUTPUT -p udp --dport 53 -m owner --uid-owner 0 --gid-owner 3005 -j RETURN
            iptables -t nat -A OUTPUT -j NAT_DNS_HIJACK
            ;;
    esac

    # 处理透明代理
    iptables -t mangle -A PROXY_PREROUTING -p tcp -j TPROXY --on-port "$PROXY_TCP_PORT" --tproxy-mark "$MARK_VALUE"
    iptables -t mangle -A PROXY_PREROUTING -p udp -j TPROXY --on-port "$PROXY_UDP_PORT" --tproxy-mark "$MARK_VALUE"

    iptables -t mangle -A PROXY_OUTPUT -j MARK --set-mark "$MARK_VALUE"
    log Info "TPROXY chains for IPv4 setup completed"
}

setup_redirect_chain4() {
    log Info "Setting up REDIRECT chains for IPv4"

    for c in PROXY_PREROUTING PROXY_OUTPUT BYPASS_IP BYPASS_INTERFACE PROXY_INTERFACE DNS_HIJACK_PRE DNS_HIJACK_OUT APP_CHAIN MAC_CHAIN; do
        safe_chain_create nat "$c"
    done

    # 只处理TCP
    iptables -t nat -I PREROUTING -p tcp -j PROXY_PREROUTING
    iptables -t nat -I OUTPUT -p tcp -j PROXY_OUTPUT
    log Debug "Added TCP rules to PREROUTING and OUTPUT chains (REDIRECT mode)"

    iptables -t nat -A PROXY_PREROUTING -j BYPASS_IP
    iptables -t nat -A PROXY_PREROUTING -j PROXY_INTERFACE
    iptables -t nat -A PROXY_PREROUTING -j MAC_CHAIN
    iptables -t nat -A PROXY_PREROUTING -j DNS_HIJACK_PRE

    iptables -t nat -A PROXY_OUTPUT -j BYPASS_IP
    iptables -t nat -A PROXY_OUTPUT -j BYPASS_INTERFACE
    iptables -t nat -A PROXY_OUTPUT -j APP_CHAIN
    iptables -t nat -A PROXY_OUTPUT -j DNS_HIJACK_OUT

    # 内网地址绕过
    for subnet4 in 0.0.0.0/8 10.0.0.0/8 100.0.0.0/8 127.0.0.0/8 \
        169.254.0.0/16 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 \
        192.168.0.0/16 198.51.100.0/24 203.0.113.0/24 \
        224.0.0.0/4 240.0.0.0/4 255.255.255.255/32; do
        iptables -t nat -A BYPASS_IP -d "$subnet4" -p udp ! --dport 53 -j ACCEPT
        iptables -t nat -A BYPASS_IP -d "$subnet4" ! -p udp -j ACCEPT
    done
    log Debug "Added bypass rules for private IP ranges (REDIRECT mode)"

    # 绕过中国大陆 IP（如果启用）
    if [ "$BYPASS_CN_IP" -eq 1 ]; then
        if command -v ipset > /dev/null 2>&1 && ipset list cnip > /dev/null 2>&1; then
            iptables -t nat -A BYPASS_IP -m set --match-set cnip dst -j ACCEPT
            log Debug "Added ipset-based CN IP bypass rule (REDIRECT mode)"
        else
            log Warn "ipset 'cnip' not available, skipping CN IP bypass"
        fi
    fi

    # 处理接口
    iptables -t nat -A PROXY_INTERFACE -i lo -j RETURN
    log Debug "Added loopback interface bypass rule (REDIRECT mode)"
    if [ "${PROXY_MOBILE:-1}" -eq 1 ]; then
        iptables -t nat -A PROXY_INTERFACE -i "$MOBILE_INTERFACE" -j RETURN
        log Debug "Mobile interface $MOBILE_INTERFACE will be proxied (REDIRECT mode)"
    else
        iptables -t nat -A PROXY_INTERFACE -i "$MOBILE_INTERFACE" -j ACCEPT
        iptables -t nat -A BYPASS_INTERFACE -o "$MOBILE_INTERFACE" -j ACCEPT
        log Debug "Mobile interface $MOBILE_INTERFACE will bypass proxy (REDIRECT mode)"
    fi
    if [ "${PROXY_WIFI:-1}" -eq 1 ]; then
        iptables -t nat -A PROXY_INTERFACE -i "$WIFI_INTERFACE" -j RETURN
        log Debug "WiFi interface $WIFI_INTERFACE will be proxied (REDIRECT mode)"
    else
        iptables -t nat -A PROXY_INTERFACE -i "$WIFI_INTERFACE" -j ACCEPT
        iptables -t nat -A BYPASS_INTERFACE -o "$WIFI_INTERFACE" -j ACCEPT
        log Debug "WiFi interface $WIFI_INTERFACE will bypass proxy (REDIRECT mode)"
    fi
    if [ "${PROXY_HOTSPOT:-0}" -eq 1 ]; then
        if [ "$HOTSPOT_INTERFACE" = "$WIFI_INTERFACE" ]; then
            iptables -t nat -A PROXY_INTERFACE -i "$WIFI_INTERFACE" ! -s 192.168.43.0/24 -j RETURN
            log Debug "Hotspot interface $WIFI_INTERFACE will be proxied (REDIRECT mode)"
        else
            iptables -t nat -A PROXY_INTERFACE -i "$HOTSPOT_INTERFACE" -j RETURN
            log Debug "Hotspot interface $HOTSPOT_INTERFACE will be proxied (REDIRECT mode)"
        fi
    else
        iptables -t nat -A BYPASS_INTERFACE -o "$HOTSPOT_INTERFACE" -j ACCEPT
        log Debug "Hotspot interface $HOTSPOT_INTERFACE will bypass proxy (REDIRECT mode)"
    fi
    if [ "${PROXY_USB:-0}" -eq 1 ]; then
        iptables -t nat -A PROXY_INTERFACE -i "$USB_INTERFACE" -j RETURN
        log Debug "USB interface $USB_INTERFACE will be proxied (REDIRECT mode)"
    else
        iptables -t nat -A PROXY_INTERFACE -i "$USB_INTERFACE" -j ACCEPT
        iptables -t nat -A BYPASS_INTERFACE -o "$USB_INTERFACE" -j ACCEPT
        log Debug "USB interface $USB_INTERFACE will bypass proxy (REDIRECT mode)"
    fi
    iptables -t nat -A PROXY_INTERFACE -j ACCEPT
    log Debug "Default proxy interface rule added (REDIRECT mode)"

    # 处理 MAC 地址黑白名单（热点模式）
    if [ "$MAC_FILTER_ENABLE" -eq 1 ] && [ -n "$HOTSPOT_INTERFACE" ]; then
        log Debug "Setting up MAC address filter rules for interface $HOTSPOT_INTERFACE (REDIRECT mode)"
        case "$MAC_PROXY_MODE" in
            blacklist)
                if [ -n "$BYPASS_MACS_LIST" ]; then
                    for mac in $BYPASS_MACS_LIST; do
                        [ -n "$mac" ] && {
                            iptables -t nat -A MAC_CHAIN -m mac --mac-source "$mac" -i "$HOTSPOT_INTERFACE" -j ACCEPT
                            log Debug "Added MAC bypass rule for $mac (REDIRECT mode)"
                        }
                    done
                fi
                iptables -t nat -A MAC_CHAIN -i "$HOTSPOT_INTERFACE" -j RETURN
                ;;
            whitelist)
                if [ -n "$PROXY_MACS_LIST" ]; then
                    for mac in $PROXY_MACS_LIST; do
                        [ -n "$mac" ] && {
                            iptables -t nat -A MAC_CHAIN -m mac --mac-source "$mac" -i "$HOTSPOT_INTERFACE" -j RETURN
                            log Debug "Added MAC proxy rule for $mac (REDIRECT mode)"
                        }
                    done
                fi
                iptables -t nat -A MAC_CHAIN -i "$HOTSPOT_INTERFACE" -j ACCEPT
                ;;
        esac
    fi

    # 绕过本机代理程序自身
    if check_kernel_feature "NETFILTER_XT_MATCH_OWNER"; then
        iptables -t nat -A APP_CHAIN -m owner --uid-owner "$CORE_USER" --gid-owner "$CORE_GROUP" -j ACCEPT
        log Debug "Added bypass for core user $CORE_USER:$CORE_GROUP (REDIRECT mode)"
    elif check_kernel_feature "NETFILTER_XT_MATCH_MARK"; then
        iptables -t mangle -A APP_CHAIN -m mark --mark "$ROUTING_MARK" -j ACCEPT
        log Debug "Added bypass for marked traffic with mark $ROUTING_MARK (REDIRECT mode)"
    fi
    # 处理黑白名单
    if [ "${APP_PROXY_ENABLE:-0}" -eq 1 ] && check_kernel_feature "NETFILTER_XT_MATCH_OWNER"; then
        # 根据模式填充
        case "$APP_PROXY_MODE" in
            blacklist)
                if [ -n "$BYPASS_APPS_LIST" ]; then
                    uids=$(find_packages_uid "$BYPASS_APPS_LIST" || true)
                    for uid in $uids; do
                        [ -n "$uid" ] && {
                            iptables -t nat -A APP_CHAIN -m owner --uid-owner "$uid" -j ACCEPT
                            log Debug "Added bypass for UID $uid (REDIRECT mode)"
                        }
                    done
                fi
                iptables -t nat -A APP_CHAIN -j RETURN
                ;;
            whitelist)
                if [ -n "$PROXY_APPS_LIST" ]; then
                    uids=$(find_packages_uid "$PROXY_APPS_LIST" || true)
                    for uid in $uids; do
                        [ -n "$uid" ] && {
                            iptables -t nat -A APP_CHAIN -m owner --uid-owner "$uid" -j RETURN
                            log Debug "Added proxy for UID $uid (REDIRECT mode)"
                        }
                    done
                fi
                iptables -t nat -A APP_CHAIN -j ACCEPT
                ;;
        esac
    fi

    # DNS 劫持
    case "${DNS_HIJACK_ENABLE:-1}" in
        1 | 2)
            # 使用REDIRECT方式处理DNS
            iptables -t nat -A DNS_HIJACK_PRE -p tcp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
            iptables -t nat -A DNS_HIJACK_PRE -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
            iptables -t nat -A DNS_HIJACK_OUT -p tcp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
            iptables -t nat -A DNS_HIJACK_OUT -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
            log Debug "DNS hijack enabled using REDIRECT mode to port $DNS_PORT"
            ;;
    esac

    # 处理透明代理
    iptables -t nat -A PROXY_PREROUTING -j REDIRECT --to-ports "$PROXY_TCP_PORT"
    iptables -t nat -A PROXY_OUTPUT -j REDIRECT --to-ports "$PROXY_TCP_PORT"
    log Info "REDIRECT chains for IPv4 setup completed"
}

setup_tproxy_chain6() {
    log Info "Setting up TPROXY chains for IPv6"

    for c6 in PROXY_PREROUTING6 PROXY_OUTPUT6 BYPASS_IP6 BYPASS_INTERFACE6 PROXY_INTERFACE6 DNS_HIJACK_PRE6 DNS_HIJACK_OUT6 APP_CHAIN6 MAC_CHAIN6; do
        safe_chain_create6 mangle "$c6"
    done

    if [ "${PROXY_TCP:-1}" -eq 1 ]; then
        ip6tables -t mangle -I PREROUTING -p tcp -j PROXY_PREROUTING6
        ip6tables -t mangle -I OUTPUT -p tcp -j PROXY_OUTPUT6
        log Debug "Added IPv6 TCP rules to PREROUTING and OUTPUT chains"
    fi
    if [ "${PROXY_UDP:-1}" -eq 1 ]; then
        ip6tables -t mangle -I PREROUTING -p udp -j PROXY_PREROUTING6
        ip6tables -t mangle -I OUTPUT -p udp -j PROXY_OUTPUT6
        log Debug "Added IPv6 UDP rules to PREROUTING and OUTPUT chains"
    fi

    ip6tables -t mangle -A PROXY_PREROUTING6 -j BYPASS_IP6
    ip6tables -t mangle -A PROXY_PREROUTING6 -j PROXY_INTERFACE6
    ip6tables -t mangle -A PROXY_PREROUTING6 -j MAC_CHAIN6
    ip6tables -t mangle -A PROXY_PREROUTING6 -j DNS_HIJACK_PRE6

    ip6tables -t mangle -A PROXY_OUTPUT6 -j BYPASS_IP6
    ip6tables -t mangle -A PROXY_OUTPUT6 -j BYPASS_INTERFACE6
    ip6tables -t mangle -A PROXY_OUTPUT6 -j APP_CHAIN6
    ip6tables -t mangle -A PROXY_OUTPUT6 -j DNS_HIJACK_OUT6

    # 内网地址绕过
    if check_kernel_feature "NETFILTER_XT_MATCH_ADDRTYPE"; then
        ip6tables -t mangle -A BYPASS_IP6 -m addrtype --dst-type LOCAL -j RETURN
        log Debug "Added IPv6 local address type bypass"
    fi
    for subnet6 in ::/128 ::1/128 ::ffff:0:0/96 \
        100::/64 64:ff9b::/96 2001::/32 2001:10::/28 \
        2001:20::/28 2001:db8::/32 \
        2002::/16 fe80::/10 ff00::/8; do
        ip6tables -t mangle -A BYPASS_IP6 -d "$subnet6" -p udp ! --dport 53 -j ACCEPT
        ip6tables -t mangle -A BYPASS_IP6 -d "$subnet6" ! -p udp -j ACCEPT
    done
    log Debug "Added bypass rules for IPv6 private IP ranges"

    # 绕过中国大陆 IPv6（如果启用）
    if [ "$BYPASS_CN_IP" -eq 1 ]; then
        if command -v ipset > /dev/null 2>&1 && ipset list cnip6 > /dev/null 2>&1; then
            ip6tables -t mangle -A BYPASS_IP6 -m set --match-set cnip6 dst -j ACCEPT
            log Debug "Added ipset-based CN IPv6 bypass rule"
        else
            log Warn "ipset 'cnip6' not available, skipping CN IPv6 bypass"
        fi
    fi

    # 处理接口
    ip6tables -t mangle -A PROXY_INTERFACE6 -i lo -j RETURN
    log Debug "Added IPv6 loopback interface bypass rule"
    if [ "${PROXY_MOBILE:-1}" -eq 1 ]; then
        ip6tables -t mangle -A PROXY_INTERFACE6 -i "$MOBILE_INTERFACE" -j RETURN
        log Debug "IPv6 Mobile interface $MOBILE_INTERFACE will be proxied"
    else
        ip6tables -t mangle -A PROXY_INTERFACE6 -i "$MOBILE_INTERFACE" -j ACCEPT
        ip6tables -t mangle -A BYPASS_INTERFACE6 -o "$MOBILE_INTERFACE" -j ACCEPT
        log Debug "IPv6 Mobile interface $MOBILE_INTERFACE will bypass proxy"
    fi
    if [ "${PROXY_WIFI:-1}" -eq 1 ]; then
        ip6tables -t mangle -A PROXY_INTERFACE6 -i "$WIFI_INTERFACE" -j RETURN
        log Debug "IPv6 WiFi interface $WIFI_INTERFACE will be proxied"
    else
        ip6tables -t mangle -A PROXY_INTERFACE6 -i "$WIFI_INTERFACE" -j ACCEPT
        ip6tables -t mangle -A BYPASS_INTERFACE6 -o "$WIFI_INTERFACE" -j ACCEPT
        log Debug "IPv6 WiFi interface $WIFI_INTERFACE will bypass proxy"
    fi
    if [ "${PROXY_HOTSPOT:-0}" -eq 1 ]; then
        if [ "$HOTSPOT_INTERFACE" != "$WIFI_INTERFACE" ]; then
            ip6tables -t mangle -A PROXY_INTERFACE6 -i "$HOTSPOT_INTERFACE" -j RETURN
            log Debug "IPv6 Hotspot interface $HOTSPOT_INTERFACE will be proxied"
        fi
    else
        ip6tables -t mangle -A BYPASS_INTERFACE6 -o "$HOTSPOT_INTERFACE" -j ACCEPT
        log Debug "IPv6 Hotspot interface $HOTSPOT_INTERFACE will bypass proxy"
    fi
    if [ "${PROXY_USB:-0}" -eq 1 ]; then
        ip6tables -t mangle -A PROXY_INTERFACE6 -i "$USB_INTERFACE" -j RETURN
        log Debug "IPv6 USB interface $USB_INTERFACE will be proxied"
    else
        ip6tables -t mangle -A PROXY_INTERFACE6 -i "$USB_INTERFACE" -j ACCEPT
        ip6tables -t mangle -A BYPASS_INTERFACE6 -o "$USB_INTERFACE" -j ACCEPT
        log Debug "IPv6 USB interface $USB_INTERFACE will bypass proxy"
    fi
    ip6tables -t mangle -A PROXY_INTERFACE6 -j ACCEPT
    log Debug "Default IPv6 proxy interface rule added"

    # 处理 MAC 地址黑白名单（热点模式）
    if [ "$MAC_FILTER_ENABLE" -eq 1 ] && [ -n "$HOTSPOT_INTERFACE" ]; then
        log Debug "Setting up IPv6 MAC address filter rules for interface $HOTSPOT_INTERFACE"
        case "$MAC_PROXY_MODE" in
            blacklist)
                if [ -n "$BYPASS_MACS_LIST" ]; then
                    for mac in $BYPASS_MACS_LIST; do
                        [ -n "$mac" ] && {
                            ip6tables -t mangle -A MAC_CHAIN6 -m mac --mac-source "$mac" -i "$HOTSPOT_INTERFACE" -j ACCEPT
                            log Debug "Added IPv6 MAC bypass rule for $mac"
                        }
                    done
                fi
                ip6tables -t mangle -A MAC_CHAIN6 -i "$HOTSPOT_INTERFACE" -j RETURN
                ;;
            whitelist)
                if [ -n "$PROXY_MACS_LIST" ]; then
                    for mac in $PROXY_MACS_LIST; do
                        [ -n "$mac" ] && {
                            ip6tables -t mangle -A MAC_CHAIN6 -m mac --mac-source "$mac" -i "$HOTSPOT_INTERFACE" -j RETURN
                            log Debug "Added IPv6 MAC proxy rule for $mac"
                        }
                    done
                fi
                ip6tables -t mangle -A MAC_CHAIN6 -i "$HOTSPOT_INTERFACE" -j ACCEPT
                ;;
        esac
    fi

    # 绕过本机代理程序自身
    if check_kernel_feature "NETFILTER_XT_MATCH_OWNER"; then
        ip6tables -t mangle -A APP_CHAIN6 -m owner --uid-owner "$CORE_USER" --gid-owner "$CORE_GROUP" -j ACCEPT
        log Debug "Added IPv6 bypass for core user $CORE_USER:$CORE_GROUP"
    elif check_kernel_feature "NETFILTER_XT_MATCH_MARK"; then
        ip6tables -t mangle -A APP_CHAIN6 -m mark --mark "$ROUTING_MARK" -j ACCEPT
        log Debug "Added IPv6 bypass for marked traffic with mark $ROUTING_MARK"
    fi

    # 处理黑白名单
    if [ "${APP_PROXY_ENABLE:-0}" -eq 1 ] && check_kernel_feature "NETFILTER_XT_MATCH_OWNER"; then
        # 根据模式填充
        case "$APP_PROXY_MODE" in
            blacklist)
                if [ -n "$BYPASS_APPS_LIST" ]; then
                    uids=$(find_packages_uid "$BYPASS_APPS_LIST" || true)
                    for uid in $uids; do
                        [ -n "$uid" ] && {
                            ip6tables -t mangle -A APP_CHAIN6 -m owner --uid-owner "$uid" -j ACCEPT
                            log Debug "Added IPv6 bypass for UID $uid"
                        }
                    done
                fi
                ip6tables -t mangle -A APP_CHAIN6 -j RETURN
                ;;
            whitelist)
                if [ -n "$PROXY_APPS_LIST" ]; then
                    uids=$(find_packages_uid "$PROXY_APPS_LIST" || true)
                    for uid in $uids; do
                        [ -n "$uid" ] && {
                            ip6tables -t mangle -A APP_CHAIN6 -m owner --uid-owner "$uid" -j RETURN
                            log Debug "Added IPv6 proxy for UID $uid"
                        }
                    done
                fi
                ip6tables -t mangle -A APP_CHAIN6 -j ACCEPT
                ;;
        esac
    fi

    # DNS 劫持
    case "${DNS_HIJACK_ENABLE:-1}" in
        1)
            # DNS_HIJACK_PRE 处理来自接口的 DNS （PREROUTING）
            ip6tables -t mangle -A DNS_HIJACK_PRE6 -p tcp --dport 53 -j TPROXY --on-port "$PROXY_TCP_PORT" --tproxy-mark "$MARK_VALUE6"
            ip6tables -t mangle -A DNS_HIJACK_PRE6 -p udp --dport 53 -j TPROXY --on-port "$PROXY_UDP_PORT" --tproxy-mark "$MARK_VALUE6"
            # DNS_HIJACK_OUT 用于 OUTPUT 的本地 DNS 劫持
            ip6tables -t mangle -A DNS_HIJACK_OUT6 -p tcp --dport 53 -j MARK --set-mark "$MARK_VALUE6"
            ip6tables -t mangle -A DNS_HIJACK_OUT6 -p udp --dport 53 -j MARK --set-mark "$MARK_VALUE6"
            log Debug "IPv6 DNS hijack enabled using TPROXY mode"
            ;;
        2)
            # 非 TPROXY 方式接收 DNS 流量
            if check_kernel_feature "IP6_NF_NAT" && check_kernel_feature "IP6_NF_TARGET_REDIRECT"; then
                safe_chain_create6 nat "NAT_DNS_HIJACK6"
                ip6tables -t nat -A NAT_DNS_HIJACK6 -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
                log Debug "IPv6 DNS hijack enabled using REDIRECT mode to port $DNS_PORT"

                [ "${PROXY_MOBILE:-1}" -eq 1 ] && ip6tables -t nat -A PREROUTING -i "$MOBILE_INTERFACE" -j NAT_DNS_HIJACK6
                [ "${PROXY_WIFI:-1}" -eq 1 ] && ip6tables -t nat -A PREROUTING -i "$WIFI_INTERFACE" -j NAT_DNS_HIJACK6

                ip6tables -t nat -A OUTPUT -p udp --dport 53 -m owner --uid-owner 0 --gid-owner 3005 -j RETURN
                ip6tables -t nat -A OUTPUT -j NAT_DNS_HIJACK6
            fi
            ;;
    esac

    # 处理透明代理
    ip6tables -t mangle -A PROXY_PREROUTING6 -p tcp -j TPROXY --on-port "$PROXY_TCP_PORT" --tproxy-mark "$MARK_VALUE6"
    ip6tables -t mangle -A PROXY_PREROUTING6 -p udp -j TPROXY --on-port "$PROXY_UDP_PORT" --tproxy-mark "$MARK_VALUE6"

    ip6tables -t mangle -A PROXY_OUTPUT6 -j MARK --set-mark "$MARK_VALUE6"
    log Info "TPROXY chains for IPv6 setup completed"
}

setup_redirect_chain6() {
    log Info "Setting up REDIRECT chains for IPv6"

    if ! check_kernel_feature "IP6_NF_NAT" || ! check_kernel_feature "IP6_NF_TARGET_REDIRECT"; then
        log Warn "IPv6: Kernel does not support IPv6 NAT or REDIRECT, skipping IPv6 proxy setup"
        return
    fi

    for c6 in PROXY_PREROUTING6 PROXY_OUTPUT6 BYPASS_IP6 BYPASS_INTERFACE6 PROXY_INTERFACE6 DNS_HIJACK_PRE6 DNS_HIJACK_OUT6 APP_CHAIN6 MAC_CHAIN6; do
        safe_chain_create6 nat "$c6"
    done

    # 只处理TCP
    ip6tables -t nat -I PREROUTING -p tcp -j PROXY_PREROUTING6
    ip6tables -t nat -I OUTPUT -p tcp -j PROXY_OUTPUT6
    log Debug "Added IPv6 TCP rules to PREROUTING and OUTPUT chains (REDIRECT mode)"

    ip6tables -t nat -A PROXY_PREROUTING6 -j BYPASS_IP6
    ip6tables -t nat -A PROXY_PREROUTING6 -j PROXY_INTERFACE6
    ip6tables -t nat -A PROXY_PREROUTING6 -j MAC_CHAIN6
    ip6tables -t nat -A PROXY_PREROUTING6 -j DNS_HIJACK_PRE6

    ip6tables -t nat -A PROXY_OUTPUT6 -j BYPASS_IP6
    ip6tables -t nat -A PROXY_OUTPUT6 -j BYPASS_INTERFACE6
    ip6tables -t nat -A PROXY_OUTPUT6 -j APP_CHAIN6
    ip6tables -t nat -A PROXY_OUTPUT6 -j DNS_HIJACK_OUT6

    # 内网地址绕过
    for subnet6 in ::/128 ::1/128 ::ffff:0:0/96 \
        100::/64 64:ff9b::/96 2001::/32 2001:10::/28 \
        2001:20::/28 2001:db8::/32 \
        2002::/16 fe80::/10 ff00::/8; do
        ip6tables -t nat -A BYPASS_IP6 -d "$subnet6" -p udp ! --dport 53 -j ACCEPT
        ip6tables -t nat -A BYPASS_IP6 -d "$subnet6" ! -p udp -j ACCEPT
    done
    log Debug "Added bypass rules for IPv6 private IP ranges (REDIRECT mode)"

    # 绕过中国大陆 IPv6（如果启用）
    if [ "$BYPASS_CN_IP" -eq 1 ]; then
        if command -v ipset > /dev/null 2>&1 && ipset list cnip6 > /dev/null 2>&1; then
            ip6tables -t nat -A BYPASS_IP6 -m set --match-set cnip6 dst -j ACCEPT
            log Debug "Added ipset-based CN IPv6 bypass rule (REDIRECT mode)"
        else
            log Warn "ipset 'cnip6' not available, skipping CN IPv6 bypass"
        fi
    fi

    # 处理接口
    ip6tables -t nat -A PROXY_INTERFACE6 -i lo -j RETURN
    log Debug "Added IPv6 loopback interface bypass rule (REDIRECT mode)"
    if [ "${PROXY_MOBILE:-1}" -eq 1 ]; then
        ip6tables -t nat -A PROXY_INTERFACE6 -i "$MOBILE_INTERFACE" -j RETURN
        log Debug "IPv6 Mobile interface $MOBILE_INTERFACE will be proxied (REDIRECT mode)"
    else
        ip6tables -t nat -A PROXY_INTERFACE6 -i "$MOBILE_INTERFACE" -j ACCEPT
        ip6tables -t nat -A BYPASS_INTERFACE6 -o "$MOBILE_INTERFACE" -j ACCEPT
        log Debug "IPv6 Mobile interface $MOBILE_INTERFACE will bypass proxy (REDIRECT mode)"
    fi
    if [ "${PROXY_WIFI:-1}" -eq 1 ]; then
        ip6tables -t nat -A PROXY_INTERFACE6 -i "$WIFI_INTERFACE" -j RETURN
        log Debug "IPv6 WiFi interface $WIFI_INTERFACE will be proxied (REDIRECT mode)"
    else
        ip6tables -t nat -A PROXY_INTERFACE6 -i "$WIFI_INTERFACE" -j ACCEPT
        ip6tables -t nat -A BYPASS_INTERFACE6 -o "$WIFI_INTERFACE" -j ACCEPT
        log Debug "IPv6 WiFi interface $WIFI_INTERFACE will bypass proxy (REDIRECT mode)"
    fi
    if [ "${PROXY_HOTSPOT:-0}" -eq 1 ]; then
        if [ "$HOTSPOT_INTERFACE" = "$WIFI_INTERFACE" ]; then
            ip6tables -t nat -A PROXY_INTERFACE6 -i "$WIFI_INTERFACE" ! -s 192.168.43.0/24 -j RETURN
            log Debug "IPv6 Hotspot interface $WIFI_INTERFACE will be proxied (REDIRECT mode)"
        else
            ip6tables -t nat -A PROXY_INTERFACE6 -i "$HOTSPOT_INTERFACE" -j RETURN
            log Debug "IPv6 Hotspot interface $HOTSPOT_INTERFACE will be proxied (REDIRECT mode)"
        fi
    else
        ip6tables -t nat -A BYPASS_INTERFACE6 -o "$HOTSPOT_INTERFACE" -j ACCEPT
        log Debug "IPv6 Hotspot interface $HOTSPOT_INTERFACE will bypass proxy (REDIRECT mode)"
    fi
    if [ "${PROXY_USB:-0}" -eq 1 ]; then
        ip6tables -t nat -A PROXY_INTERFACE6 -i "$USB_INTERFACE" -j RETURN
        log Debug "IPv6 USB interface $USB_INTERFACE will be proxied (REDIRECT mode)"
    else
        ip6tables -t nat -A PROXY_INTERFACE6 -i "$USB_INTERFACE" -j ACCEPT
        ip6tables -t nat -A BYPASS_INTERFACE6 -o "$USB_INTERFACE" -j ACCEPT
        log Debug "IPv6 USB interface $USB_INTERFACE will bypass proxy (REDIRECT mode)"
    fi
    ip6tables -t nat -A PROXY_INTERFACE6 -j ACCEPT
    log Debug "Default IPv6 proxy interface rule added (REDIRECT mode)"

    # 处理 MAC 地址黑白名单（热点模式）
    if [ "$MAC_FILTER_ENABLE" -eq 1 ] && [ -n "$HOTSPOT_INTERFACE" ]; then
        log Debug "Setting up IPv6 MAC address filter rules for interface $HOTSPOT_INTERFACE (REDIRECT mode)"
        case "$MAC_PROXY_MODE" in
            blacklist)
                if [ -n "$BYPASS_MACS_LIST" ]; then
                    for mac in $BYPASS_MACS_LIST; do
                        [ -n "$mac" ] && {
                            ip6tables -t nat -A MAC_CHAIN6 -m mac --mac-source "$mac" -i "$HOTSPOT_INTERFACE" -j ACCEPT
                            log Debug "Added IPv6 MAC bypass rule for $mac (REDIRECT mode)"
                        }
                    done
                fi
                ip6tables -t nat -A MAC_CHAIN6 -i "$HOTSPOT_INTERFACE" -j RETURN
                ;;
            whitelist)
                if [ -n "$PROXY_MACS_LIST" ]; then
                    for mac in $PROXY_MACS_LIST; do
                        [ -n "$mac" ] && {
                            ip6tables -t nat -A MAC_CHAIN6 -m mac --mac-source "$mac" -i "$HOTSPOT_INTERFACE" -j RETURN
                            log Debug "Added IPv6 MAC proxy rule for $mac (REDIRECT mode)"
                        }
                    done
                fi
                ip6tables -t nat -A MAC_CHAIN6 -i "$HOTSPOT_INTERFACE" -j ACCEPT
                ;;
        esac
    fi

    # 绕过本机代理程序自身
    if check_kernel_feature "NETFILTER_XT_MATCH_OWNER"; then
        ip6tables -t nat -A APP_CHAIN6 -m owner --uid-owner "$CORE_USER" --gid-owner "$CORE_GROUP" -j ACCEPT
        log Debug "Added IPv6 bypass for core user $CORE_USER:$CORE_GROUP (REDIRECT mode)"
    elif check_kernel_feature "NETFILTER_XT_MATCH_MARK"; then
        ip6tables -t nat -A APP_CHAIN6 -m mark --mark "$ROUTING_MARK" -j ACCEPT
        log Debug "Added IPv6 bypass for marked traffic with mark $ROUTING_MARK (REDIRECT mode)"
    fi
    # 处理黑白名单
    if [ "${APP_PROXY_ENABLE:-0}" -eq 1 ] && check_kernel_feature "NETFILTER_XT_MATCH_OWNER"; then
        # 根据模式填充
        case "$APP_PROXY_MODE" in
            blacklist)
                if [ -n "$BYPASS_APPS_LIST" ]; then
                    uids=$(find_packages_uid "$BYPASS_APPS_LIST" || true)
                    for uid in $uids; do
                        [ -n "$uid" ] && {
                            ip6tables -t nat -A APP_CHAIN6 -m owner --uid-owner "$uid" -j ACCEPT
                            log Debug "Added IPv6 bypass for UID $uid (REDIRECT mode)"
                        }
                    done
                fi
                ip6tables -t nat -A APP_CHAIN6 -j RETURN
                ;;
            whitelist)
                if [ -n "$PROXY_APPS_LIST" ]; then
                    uids=$(find_packages_uid "$PROXY_APPS_LIST" || true)
                    for uid in $uids; do
                        [ -n "$uid" ] && {
                            ip6tables -t nat -A APP_CHAIN6 -m owner --uid-owner "$uid" -j RETURN
                            log Debug "Added IPv6 proxy for UID $uid (REDIRECT mode)"
                        }
                    done
                fi
                ip6tables -t nat -A APP_CHAIN -j ACCEPT
                ;;
        esac
    fi

    # DNS 劫持
    case "${DNS_HIJACK_ENABLE:-1}" in
        1 | 2)
            # 使用REDIRECT方式处理DNS
            ip6tables -t nat -A DNS_HIJACK_PRE6 -p tcp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
            ip6tables -t nat -A DNS_HIJACK_PRE6 -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
            ip6tables -t nat -A DNS_HIJACK_OUT6 -p tcp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
            ip6tables -t nat -A DNS_HIJACK_OUT6 -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
            log Debug "IPv6 DNS hijack enabled using REDIRECT mode to port $DNS_PORT"
            ;;
    esac

    # 处理透明代理
    ip6tables -t nat -A PROXY_PREROUTING6 -j REDIRECT --to-ports "$PROXY_TCP_PORT"
    ip6tables -t nat -A PROXY_OUTPUT6 -j REDIRECT --to-ports "$PROXY_TCP_PORT"
    log Info "REDIRECT chains for IPv6 setup completed"
}

setup_routing4() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log Debug "DRY-RUN: Skipping actual routing setup"
        return
    fi
    ip_rule del fwmark "$MARK_VALUE" table "$TABLE_ID" pref "$TABLE_ID" > /dev/null 2>&1 || true
    ip_route del local default dev lo table "$TABLE_ID" > /dev/null 2>&1 || true
    ip_rule add fwmark "$MARK_VALUE" table "$TABLE_ID" pref "$TABLE_ID"
    ip_route add local default dev lo table "$TABLE_ID"
    echo 1 > /proc/sys/net/ipv4/ip_forward
    log Info "IPv4 routing setup completed"
}

setup_routing6() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log Debug "DRY-RUN: Skipping actual IPv6 routing setup"
        return
    fi
    ip6_rule del fwmark "$MARK_VALUE6" table "$TABLE_ID" pref "$TABLE_ID" > /dev/null 2>&1 || true
    ip6_route del local default dev lo table "$TABLE_ID" > /dev/null 2>&1 || true
    ip6_rule add fwmark "$MARK_VALUE6" table "$TABLE_ID" pref "$TABLE_ID"
    ip6_route add local default dev lo table "$TABLE_ID"
    echo 1 > /proc/sys/net/ipv6/ip_forward
    log Info "IPv6 routing setup completed"
}

cleanup_routing4() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log Debug "DRY-RUN: Skipping actual routing cleanup"
        return
    fi
    ip_rule del fwmark "$MARK_VALUE" table "$TABLE_ID" pref "$TABLE_ID" 2> /dev/null || true
    ip_route del local default dev lo table "$TABLE_ID" 2> /dev/null || true
    echo 0 > /proc/sys/net/ipv4/ip_forward
    log Info "IPv4 routing cleanup completed"
}

cleanup_routing6() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log Debug "DRY-RUN: Skipping actual IPv6 routing cleanup"
        return
    fi
    ip6_rule del fwmark "$MARK_VALUE6" table "$TABLE_ID" pref "$TABLE_ID" 2> /dev/null || true
    ip6_route del local default dev lo table "$TABLE_ID" 2> /dev/null || true
    echo 0 > /proc/sys/net/ipv6/ip_forward
    log Info "IPv6 routing cleanup completed"
}

cleanup_tproxy_chain4() {
    log Info "Cleaning up TPROXY chains for IPv4"

    iptables -t mangle -D PROXY_PREROUTING -j BYPASS_IP 2> /dev/null || true
    iptables -t mangle -D PROXY_PREROUTING -j PROXY_INTERFACE 2> /dev/null || true
    iptables -t mangle -D PROXY_PREROUTING -j MAC_CHAIN 2> /dev/null || true
    iptables -t mangle -D PROXY_PREROUTING -j DNS_HIJACK_PRE 2> /dev/null || true

    iptables -t mangle -D PROXY_OUTPUT -j BYPASS_IP 2> /dev/null || true
    iptables -t mangle -D PROXY_OUTPUT -j BYPASS_INTERFACE 2> /dev/null || true
    iptables -t mangle -D PROXY_OUTPUT -j APP_CHAIN 2> /dev/null || true
    iptables -t mangle -D PROXY_OUTPUT -j DNS_HIJACK_OUT 2> /dev/null || true

    if [ "${PROXY_TCP:-1}" -eq 1 ]; then
        iptables -t mangle -D PREROUTING -p tcp -j PROXY_PREROUTING 2> /dev/null || true
        iptables -t mangle -D OUTPUT -p tcp -j PROXY_OUTPUT 2> /dev/null || true
        log Debug "Removed TCP rules from PREROUTING and OUTPUT chains"
    fi
    if [ "${PROXY_UDP:-1}" -eq 1 ]; then
        iptables -t mangle -D PREROUTING -p udp -j PROXY_PREROUTING 2> /dev/null || true
        iptables -t mangle -D OUTPUT -p udp -j PROXY_OUTPUT 2> /dev/null || true
        log Debug "Removed UDP rules from PREROUTING and OUTPUT chains"
    fi

    for c in PROXY_PREROUTING PROXY_OUTPUT BYPASS_IP BYPASS_INTERFACE PROXY_INTERFACE DNS_HIJACK_PRE DNS_HIJACK_OUT APP_CHAIN MAC_CHAIN; do
        iptables -t mangle -F "$c" 2> /dev/null || true
        iptables -t mangle -X "$c" 2> /dev/null || true
        log Debug "Flushed and deleted chain $c"
    done

    if [ "$DNS_HIJACK_ENABLE" -eq 2 ]; then
        iptables -t nat -D PREROUTING -i "$MOBILE_INTERFACE" -j NAT_DNS_HIJACK 2> /dev/null || true
        iptables -t nat -D PREROUTING -i "$WIFI_INTERFACE" -j NAT_DNS_HIJACK 2> /dev/null || true
        iptables -t nat -D OUTPUT -p udp --dport 53 -m owner --uid-owner 0 --gid-owner 3005 -j RETURN 2> /dev/null || true
        iptables -t nat -D OUTPUT -j NAT_DNS_HIJACK 2> /dev/null || true
        iptables -t nat -F NAT_DNS_HIJACK 2> /dev/null || true
        iptables -t nat -X NAT_DNS_HIJACK 2> /dev/null || true
        log Debug "Removed and cleaned up NAT DNS hijack chains"
    fi
    log Info "TPROXY chains for IPv4 cleanup completed"
}

cleanup_tproxy_chain6() {
    log Info "Cleaning up TPROXY chains for IPv6"

    ip6tables -t mangle -D PROXY_PREROUTING6 -j BYPASS_IP6 2> /dev/null || true
    ip6tables -t mangle -D PROXY_PREROUTING6 -j PROXY_INTERFACE6 2> /dev/null || true
    ip6tables -t mangle -D PROXY_PREROUTING6 -j MAC_CHAIN6 2> /dev/null || true
    ip6tables -t mangle -D PROXY_PREROUTING6 -j DNS_HIJACK_PRE6 2> /dev/null || true

    ip6tables -t mangle -D PROXY_OUTPUT6 -j BYPASS_IP6 2> /dev/null || true
    ip6tables -t mangle -D PROXY_OUTPUT6 -j BYPASS_INTERFACE6 2> /dev/null || true
    ip6tables -t mangle -D PROXY_OUTPUT6 -j APP_CHAIN6 2> /dev/null || true
    ip6tables -t mangle -D PROXY_OUTPUT6 -j DNS_HIJACK_OUT6 2> /dev/null || true

    if [ "${PROXY_TCP:-1}" -eq 1 ]; then
        ip6tables -t mangle -D PREROUTING -p tcp -j PROXY_PREROUTING6 2> /dev/null || true
        ip6tables -t mangle -D OUTPUT -p tcp -j PROXY_OUTPUT6 2> /dev/null || true
        log Debug "Removed IPv6 TCP rules from PREROUTING and OUTPUT chains"
    fi
    if [ "${PROXY_UDP:-1}" -eq 1 ]; then
        ip6tables -t mangle -D PREROUTING -p udp -j PROXY_PREROUTING6 2> /dev/null || true
        ip6tables -t mangle -D OUTPUT -p udp -j PROXY_OUTPUT6 2> /dev/null || true
        log Debug "Removed IPv6 UDP rules from PREROUTING and OUTPUT chains"
    fi

    for c6 in PROXY_PREROUTING6 PROXY_OUTPUT6 BYPASS_IP6 BYPASS_INTERFACE6 PROXY_INTERFACE6 DNS_HIJACK_PRE6 DNS_HIJACK_OUT6 APP_CHAIN6 MAC_CHAIN6; do
        ip6tables -t mangle -F "$c6" 2> /dev/null || true
        ip6tables -t mangle -X "$c6" 2> /dev/null || true
        log Debug "Flushed and deleted IPv6 chain $c6"
    done

    if [ "$DNS_HIJACK_ENABLE" -eq 2 ]; then
        ip6tables -t nat -D PREROUTING -i "$MOBILE_INTERFACE" -j NAT_DNS_HIJACK6 2> /dev/null || true
        ip6tables -t nat -D PREROUTING -i "$WIFI_INTERFACE" -j NAT_DNS_HIJACK6 2> /dev/null || true
        ip6tables -t nat -D OUTPUT -p udp --dport 53 -m owner --uid-owner 0 --gid-owner 3005 -j RETURN 2> /dev/null || true
        ip6tables -t nat -D OUTPUT -j NAT_DNS_HIJACK6 2> /dev/null || true
        ip6tables -t nat -F NAT_DNS_HIJACK6 2> /dev/null || true
        ip6tables -t nat -X NAT_DNS_HIJACK6 2> /dev/null || true
        log Debug "Removed and cleaned up IPv6 NAT DNS hijack chains"
    fi
    log Info "TPROXY chains for IPv6 cleanup completed"
}

cleanup_redirect_chain4() {
    log Info "Cleaning up REDIRECT chains for IPv4"

    iptables -t nat -D PROXY_PREROUTING -j BYPASS_IP 2> /dev/null || true
    iptables -t nat -D PROXY_PREROUTING -j PROXY_INTERFACE 2> /dev/null || true
    iptables -t nat -D PROXY_PREROUTING -j MAC_CHAIN 2> /dev/null || true
    iptables -t nat -D PROXY_PREROUTING -j DNS_HIJACK_PRE 2> /dev/null || true

    iptables -t nat -D PROXY_OUTPUT -j BYPASS_IP 2> /dev/null || true
    iptables -t nat -D PROXY_OUTPUT -j BYPASS_INTERFACE 2> /dev/null || true
    iptables -t nat -D PROXY_OUTPUT -j APP_CHAIN 2> /dev/null || true
    iptables -t nat -D PROXY_OUTPUT -j DNS_HIJACK_OUT 2> /dev/null || true

    iptables -t nat -D PREROUTING -p tcp -j PROXY_PREROUTING 2> /dev/null || true
    iptables -t nat -D OUTPUT -p tcp -j PROXY_OUTPUT 2> /dev/null || true
    log Debug "Removed TCP rules from PREROUTING and OUTPUT chains (REDIRECT mode)"

    for c in PROXY_PREROUTING PROXY_OUTPUT BYPASS_IP BYPASS_INTERFACE PROXY_INTERFACE DNS_HIJACK_PRE DNS_HIJACK_OUT APP_CHAIN MAC_CHAIN; do
        iptables -t nat -F "$c" 2> /dev/null || true
        iptables -t nat -X "$c" 2> /dev/null || true
        log Debug "Flushed and deleted REDIRECT chain $c"
    done
    log Info "REDIRECT chains for IPv4 cleanup completed"
}

cleanup_redirect_chain6() {
    log Info "Cleaning up REDIRECT chains for IPv6"

    if ! check_kernel_feature "IP6_NF_NAT" || ! check_kernel_feature "IP6_NF_TARGET_REDIRECT"; then
        log Warn "IPv6: Kernel does not support IPv6 NAT or REDIRECT, skipping IPv6 cleanup"
        return
    fi

    ip6tables -t nat -D PROXY_PREROUTING6 -j BYPASS_IP6 2> /dev/null || true
    ip6tables -t nat -D PROXY_PREROUTING6 -j PROXY_INTERFACE6 2> /dev/null || true
    ip6tables -t nat -D PROXY_PREROUTING6 -j MAC_CHAIN6 2> /dev/null || true
    ip6tables -t nat -D PROXY_PREROUTING6 -j DNS_HIJACK_PRE6 2> /dev/null || true

    ip6tables -t nat -D PROXY_OUTPUT6 -j BYPASS_IP6 2> /dev/null || true
    ip6tables -t nat -D PROXY_OUTPUT6 -j BYPASS_INTERFACE6 2> /dev/null || true
    ip6tables -t nat -D PROXY_OUTPUT6 -j APP_CHAIN6 2> /dev/null || true
    ip6tables -t nat -D PROXY_OUTPUT6 -j DNS_HIJACK_OUT6 2> /dev/null || true

    ip6tables -t nat -D PREROUTING -p tcp -j PROXY_PREROUTING6 2> /dev/null || true
    ip6tables -t nat -D OUTPUT -p tcp -j PROXY_OUTPUT6 2> /dev/null || true
    log Debug "Removed IPv6 TCP rules from PREROUTING and OUTPUT chains (REDIRECT mode)"

    for c6 in PROXY_PREROUTING6 PROXY_OUTPUT6 BYPASS_IP6 BYPASS_INTERFACE6 PROXY_INTERFACE6 DNS_HIJACK_PRE6 DNS_HIJACK_OUT6 APP_CHAIN6 MAC_CHAIN6; do
        ip6tables -t nat -F "$c6" 2> /dev/null || true
        ip6tables -t nat -X "$c6" 2> /dev/null || true
        log Debug "Flushed and deleted IPv6 REDIRECT chain $c6"
    done
    log Info "REDIRECT chains for IPv6 cleanup completed"
}

# 清理 ipset
cleanup_ipset() {
    if [ "$BYPASS_CN_IP" -eq 1 ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            log Debug "[DRY-RUN] ipset destroy cnip"
            log Debug "[DRY-RUN] ipset destroy cnip6"
        else
            ipset destroy cnip 2>/dev/null && log Debug "Destroyed ipset 'cnip'"
            ipset destroy cnip6 2>/dev/null && log Debug "Destroyed ipset 'cnip6'"
        fi
    fi
}

# 主流程
main() {
    cmd="${1:-}"

    case "$cmd" in
        start)
            log Info "Starting proxy setup..."
            if [ "$BYPASS_CN_IP" -eq 1 ]; then
                # 检查内核支持和依赖
                if ! check_kernel_feature "IP_SET" || ! check_kernel_feature "NETFILTER_XT_SET"; then
                    log Error "Kernel does not support ipset (CONFIG_IP_SET, CONFIG_NETFILTER_XT_SET). Cannot bypass CN IPs."
                    BYPASS_CN_IP=0
                else
                    download_cn_ip_list || log Warn "Failed to download CN IP list, continuing without it"
                    setup_cn_ipset || log Warn "Failed to setup ipset, CN bypass disabled"
                fi
            fi

            if check_tproxy_support; then
                log Info "Kernel supports TPROXY, using TPROXY mode"
                setup_tproxy_chain4
                setup_routing4
                if [ "${PROXY_IPV6:-0}" -eq 1 ]; then
                    setup_tproxy_chain6
                    setup_routing6
                fi
            else
                log Warn "Kernel does not support TPROXY, falling back to REDIRECT mode (TCP only)"
                setup_redirect_chain4
                if [ "${PROXY_IPV6:-0}" -eq 1 ]; then
                    setup_redirect_chain6
                fi
            fi
            log Info "Proxy setup completed"
            ;;
        stop)
            log Info "Stopping proxy..."
            if check_tproxy_support; then
                log Info "Cleaning up TPROXY chains"
                cleanup_tproxy_chain4
                cleanup_routing4
                if [ "${PROXY_IPV6:-0}" -eq 1 ]; then
                    cleanup_tproxy_chain6
                    cleanup_routing6
                fi
            else
                log Info "Cleaning up REDIRECT chains"
                cleanup_redirect_chain4
                if [ "${PROXY_IPV6:-0}" -eq 1 ]; then
                    cleanup_redirect_chain6
                fi
            fi
            cleanup_ipset
            log Info "Proxy stopped"
            ;;
        restart)
            log Info "Restarting proxy..."
            if check_tproxy_support; then
                log Info "Cleaning up TPROXY chains for restart"
                cleanup_tproxy_chain4
                cleanup_routing4
                if [ "${PROXY_IPV6:-0}" -eq 1 ]; then
                    cleanup_tproxy_chain6
                    cleanup_routing6
                fi
            else
                log Info "Cleaning up REDIRECT chains for restart"
                cleanup_redirect_chain4
                if [ "${PROXY_IPV6:-0}" -eq 1 ]; then
                    cleanup_redirect_chain6
                fi
            fi
            cleanup_ipset
            sleep 2s
            if [ "$BYPASS_CN_IP" -eq 1 ]; then
                # 检查内核支持和依赖
                if ! check_kernel_feature "IP_SET" || ! check_kernel_feature "NETFILTER_XT_SET"; then
                    log Error "Kernel does not support ipset (CONFIG_IP_SET, CONFIG_NETFILTER_XT_SET). Cannot bypass CN IPs."
                    BYPASS_CN_IP=0
                else
                    download_cn_ip_list || log Warn "Failed to download CN IP list, continuing without it"
                    setup_cn_ipset || log Warn "Failed to setup ipset, CN bypass disabled"
                fi
            fi
            if check_tproxy_support; then
                log Info "Setting up TPROXY chains after restart"
                setup_tproxy_chain4
                setup_routing4
                if [ "${PROXY_IPV6:-0}" -eq 1 ]; then
                    setup_tproxy_chain6
                    setup_routing6
                fi
            else
                log Info "Setting up REDIRECT chains after restart"
                setup_redirect_chain4
                if [ "${PROXY_IPV6:-0}" -eq 1 ]; then
                    setup_redirect_chain6
                fi
            fi
            log Info "Proxy restarted"
            ;;
        *)
            log Error "Usage: %s {start|stop|restart} [--dry-run]\n" "$(basename "$0")"
            exit 1
            ;;
    esac
}

# 解析参数
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            log Debug "Dry-run mode enabled"
            shift
            ;;
        start | stop | restart)
            main_cmd="$1"
            shift
            ;;
        *)
            log Error "Usage: %s {start|stop|restart} [--dry-run]\n" "$(basename "$0")"
            exit 1
            ;;
    esac
done

if [ -z "${main_cmd:-}" ]; then
    log Error "Usage: %s {start|stop|restart} [--dry-run]\n" "$(basename "$0")"
    exit 1
fi

# 检查依赖
check_dependencies

# 验证用户组
validate_user_group

# 执行主流程
main "$main_cmd"
