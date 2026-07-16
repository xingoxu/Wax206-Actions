#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
Dev=$1
BUILD_DIR=${2:-$1}

echo "=========================================="
echo "DIY Part2 - 设备: $Dev"
echo "BUILD_DIR: $BUILD_DIR"
echo "=========================================="

echo "目标目录: $BUILD_DIR"

if [ ! -d "./$BUILD_DIR" ]; then
    echo "错误: 目录 ./$BUILD_DIR 不存在"
    ls -la
    exit 1
fi

cd "./$BUILD_DIR" || exit 1
echo "进入目录: $(pwd)"

# ==========================================
# 更新日本 5 GHz 监管功率限制
# ==========================================
REGDB_PATCH="$SCRIPT_DIR/wax206/patches/001-wireless-regdb-jp-28dbm.patch"
REGDB_PATCH_DIR="package/firmware/wireless-regdb/patches"

if [ ! -f "$REGDB_PATCH" ]; then
    echo "错误: 找不到 wireless-regdb 补丁: $REGDB_PATCH"
    exit 1
fi

mkdir -p "$REGDB_PATCH_DIR"
cp -f "$REGDB_PATCH" "$REGDB_PATCH_DIR/001-wireless-regdb-jp-28dbm.patch"
echo "✓ 已安装日本 5 GHz 28 dBm wireless-regdb 补丁"

# ==========================================
# 配置 AP 管理 IP
# ==========================================
if [ -f "package/base-files/files/bin/config_generate" ]; then
    sed -i 's/192.168.1.1/192.168.1.32/g' package/base-files/files/bin/config_generate
    echo "✓ AP 管理 IP 改为192.168.1.32"
fi

# ==========================================
# 配置主机名
# ==========================================
if [ -f "package/base-files/files/bin/config_generate" ]; then
    sed -i 's/OpenWrt/Netgear-WAX206/g' package/base-files/files/bin/config_generate
    echo "✓ 主机名改为Netgear-WAX206"
fi

# ==========================================
# 配置时区
# ==========================================
if [ -f "package/base-files/files/bin/config_generate" ]; then
    sed -i "s/timezone='.*'/timezone='JST-9'/g" package/base-files/files/bin/config_generate
    sed -i "/timezone='JST-9'/a\\\t\tset system.@system[-1].zonename='Asia/Tokyo'" package/base-files/files/bin/config_generate
    echo "✓ 时区改为Asia/Tokyo"
fi

# ==========================================
# 配置为 AP（物理 WAN 口并入 LAN 网桥）
# ==========================================
echo ">>> 写入 AP 模式首次启动配置..."

mkdir -p package/base-files/files/etc/uci-defaults

cat > package/base-files/files/etc/uci-defaults/99-ap-mode << 'APMODE'
#!/bin/sh

# 使用 LAN 网桥作为 AP 的管理接口。
uci -q batch << 'EOF'
set network.lan.proto='static'
set network.lan.ipaddr='192.168.1.32'
set network.lan.netmask='255.255.255.0'
set network.lan.gateway='192.168.1.1'
delete network.lan.dns
add_list network.lan.dns='1.1.1.1'
add_list network.lan.dns='8.8.8.8'
delete network.lan.ip6assign

# AP 不保留独立的逻辑 WAN/WAN6 接口。
delete network.wan
delete network.wan6

# 通过 LAN 网桥获取 IPv6 地址，不请求 IPv6 前缀。
set network.lan6='interface'
set network.lan6.device='@lan'
set network.lan6.proto='dhcpv6'
set network.lan6.reqaddress='try'
set network.lan6.reqprefix='no'
set network.lan6.norelease='0'

# DHCP 由上级路由器提供；本机不发放 IPv4/IPv6 地址。
set dhcp.lan.ignore='1'
set dhcp.lan.dhcpv4='disabled'
set dhcp.lan.dhcpv6='disabled'
set dhcp.lan.ndp='disabled'

# 通过 RA 发布 IPv6 DNS 和加密 DNS，但不将本 AP 通告为 IPv6 默认网关。
set dhcp.lan.ra='server'
set dhcp.lan.ra_default='2'
set dhcp.lan.ra_lifetime='0'
delete dhcp.lan.ra_flags
add_list dhcp.lan.ra_flags='none'
set dhcp.lan.ra_dns='1'
delete dhcp.lan.dns
add_list dhcp.lan.dns='2606:4700:4700::1111'
add_list dhcp.lan.dns='2001:4860:4860::8888'
delete dhcp.lan.dnr
add_list dhcp.lan.dnr='1 one.one.one.one 2606:4700:4700::1111,2606:4700:4700::1001,1.1.1.1,1.0.0.1 alpn=dot port=853'
add_list dhcp.lan.dnr='1 dns.google 2001:4860:4860::8888,2001:4860:4860::8844,8.8.8.8,8.8.4.4 alpn=dot port=853'
add_list dhcp.lan.dnr='2 cloudflare-dns.com 2606:4700:4700::1111,2606:4700:4700::1001,1.1.1.1,1.0.0.1 alpn=h2,h3 dohpath=/dns-query{?dns}'
add_list dhcp.lan.dnr='2 dns.google 2001:4860:4860::8888,2001:4860:4860::8844,8.8.8.8,8.8.4.4 alpn=h2,h3 dohpath=/dns-query{?dns}'

# 时区、时制和 LuCI 语言。
set system.@system[0].zonename='Asia/Tokyo'
set system.@system[0].timezone='JST-9'
set system.@system[0].clock_hourcycle='h23'
set luci.main.lang='zh_cn'

# 2.4 GHz 和 5 GHz 蓝色 Wi-Fi 指示灯。
delete system.wifi24_blue
set system.wifi24_blue='led'
set system.wifi24_blue.name='2.4Ghz 蓝色'
set system.wifi24_blue.sysfs='wifin:blue'
set system.wifi24_blue.trigger='netdev'
set system.wifi24_blue.dev='wl0-ap0'
add_list system.wifi24_blue.mode='link'
add_list system.wifi24_blue.mode='tx'
add_list system.wifi24_blue.mode='rx'

delete system.wifi5_blue
set system.wifi5_blue='led'
set system.wifi5_blue.name='5Ghz 蓝色'
set system.wifi5_blue.sysfs='wifia:blue'
set system.wifi5_blue.trigger='netdev'
set system.wifi5_blue.dev='wl1-ap0'
add_list system.wifi5_blue.mode='link'
add_list system.wifi5_blue.mode='tx'
add_list system.wifi5_blue.mode='rx'

# uHTTPd 仅监听 IPv4 HTTP/HTTPS。
delete uhttpd.main.listen_http
add_list uhttpd.main.listen_http='0.0.0.0:80'
delete uhttpd.main.listen_https
add_list uhttpd.main.listen_https='0.0.0.0:443'
set uhttpd.main.redirect_https='1'

# Dropbear SSH 仅绑定到 LAN 接口。
set dropbear.main.Interface='lan'
EOF

# 按频段设置无线设备，不依赖 radio0/radio1 的排列顺序。
WIRELESS_DEVICES="$({
    uci -q show wireless | sed -n "s/^\(wireless\.[^=]*\)=wifi-device$/\1/p"
} 2>/dev/null)"

for device in $WIRELESS_DEVICES; do
    band="$(uci -q get "${device}.band")"
    hwmode="$(uci -q get "${device}.hwmode")"

    case "${band}:${hwmode}" in
        2g:*|*:11g)
            uci -q set "${device}.channel=auto"
            ;;
        5g:*|*:11a)
            uci -q set "${device}.channel=44"
            uci -q set "${device}.htmode=HE160"
            ;;
    esac
done

# 为两个频段的 AP 无线接口启用 802.11k/802.11v 和 Proxy ARP。
WIRELESS_INTERFACES="$({
    uci -q show wireless | sed -n "s/^\(wireless\.[^=]*\)=wifi-iface$/\1/p"
} 2>/dev/null)"

for interface in $WIRELESS_INTERFACES; do
    if [ "$(uci -q get "${interface}.mode")" = 'ap' ]; then
        uci -q set "${interface}.ieee80211k=1"
        uci -q set "${interface}.bss_transition=1"
        uci -q set "${interface}.proxy_arp=1"
    fi
done

# 查找名称为 lan 的防火墙 zone，避免使用会变化的 cfgXXXXXX 匿名节名。
LAN_FIREWALL_ZONE="$({
    uci -q show firewall | sed -n "s/^\(firewall\.[^=]*\)=zone$/\1/p" | while read -r section; do
        if [ "$(uci -q get "${section}.name")" = 'lan' ]; then
            echo "$section"
            break
        fi
    done
} 2>/dev/null)"

if [ -n "$LAN_FIREWALL_ZONE" ]; then
    uci -q del_list "${LAN_FIREWALL_ZONE}.network=lan"
    uci -q del_list "${LAN_FIREWALL_ZONE}.network=lan6"
    uci -q add_list "${LAN_FIREWALL_ZONE}.network=lan"
    uci -q add_list "${LAN_FIREWALL_ZONE}.network=lan6"
else
    logger -t 99-ap-mode "未找到 lan 防火墙 zone，无法加入 lan6 接口"
fi

# 找到 br-lan 的 device 配置节，将物理 wan 端口加入网桥。
BR_LAN_DEVICE="$({
    uci -q show network | sed -n "s/^\(network\.[^=]*\)=device$/\1/p" | while read -r section; do
        if [ "$(uci -q get "${section}.name")" = 'br-lan' ]; then
            echo "$section"
            break
        fi
    done
} 2>/dev/null)"

if [ -n "$BR_LAN_DEVICE" ]; then
    uci -q del_list "${BR_LAN_DEVICE}.ports=wan"
    uci -q add_list "${BR_LAN_DEVICE}.ports=wan"
else
    logger -t 99-ap-mode "未找到 br-lan device 配置，无法将物理 wan 口加入 LAN 网桥"
fi

uci commit network
uci commit dhcp
uci commit system
uci commit luci
uci commit firewall
uci commit uhttpd
uci commit wireless
uci commit dropbear

exit 0
APMODE

chmod +x package/base-files/files/etc/uci-defaults/99-ap-mode
echo "✓ AP 模式：管理 IP 192.168.1.32，网关 192.168.1.1"
echo "✓ LAN DNS：1.1.1.1、8.8.8.8"
echo "✓ 物理 WAN 口将并入 br-lan"
echo "✓ DHCPv4、DHCPv6 和 NDP 已关闭"
echo "✓ IPv6 RA 已启用：SLAAC、DNS 和 DoT/DoH DNR 已预置"
echo "✓ 时区：Asia/Tokyo，24 小时制，LuCI 简体中文"
echo "✓ 2.4 GHz 和 5 GHz 蓝色 Wi-Fi 指示灯已配置"
echo "✓ LAN6 DHCPv6 客户端和 lan 防火墙 zone 已配置"
echo "✓ uHTTPd 仅监听 IPv4：0.0.0.0:80 和 0.0.0.0:443"
echo "✓ HTTP 自动重定向 HTTPS"
echo "✓ Wi-Fi：2.4 GHz 自动信道；5 GHz AX、信道 44、160 MHz"
echo "✓ 2.4 GHz 和 5 GHz AP 已启用 802.11k、BSS Transition 和 Proxy ARP"

# ========== 最后：强制覆盖 distfeeds.list ==========

echo ">>> 强制重置 distfeeds.list 为官方源..."

mkdir -p package/base-files/files/etc/apk/repositories.d/

cat > package/base-files/files/etc/apk/repositories.d/distfeeds.list << 'EOF'
# This file is auto-generated and build-specific, any changes will be intentionally lost in sysupgrade.
# Add your custom feeds to /etc/apk/repositories.d/customfeeds.list
https://downloads.openwrt.org/snapshots/targets/mediatek/mt7622/packages/packages.adb
https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/base/packages.adb
https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/luci/packages.adb
https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/packages/packages.adb
https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/routing/packages.adb
https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/telephony/packages.adb
https://downloads.openwrt.org/snapshots/packages/aarch64_cortex-a53/video/packages.adb
EOF

echo ">>> distfeeds.list 已重置："
cat package/base-files/files/etc/apk/repositories.d/distfeeds.list

# ==========================================
# Conntrack 优化配置
# ==========================================
echo "配置 conntrack 优化..."

mkdir -p package/base-files/files/etc/sysctl.d
mkdir -p package/base-files/files/etc/modules.d
mkdir -p package/base-files/files/etc/hotplug.d/iface

cat > package/base-files/files/etc/sysctl.d/99-conntrack.conf << 'EOF'
net.netfilter.nf_conntrack_max=262144
net.netfilter.nf_conntrack_tcp_timeout_established=600
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.netfilter.nf_conntrack_tcp_timeout_close_wait=10
net.netfilter.nf_conntrack_tcp_timeout_fin_wait=10
net.netfilter.nf_conntrack_tcp_timeout_syn_recv=30
net.netfilter.nf_conntrack_tcp_timeout_syn_sent=30
net.netfilter.nf_conntrack_tcp_timeout_last_ack=10
net.netfilter.nf_conntrack_udp_timeout=10
net.netfilter.nf_conntrack_udp_timeout_stream=30
net.netfilter.nf_conntrack_icmp_timeout=5
net.netfilter.nf_conntrack_log_invalid=0
net.netfilter.nf_conntrack_tcp_be_liberal=1
EOF
echo "✓ /etc/sysctl.d/99-conntrack.conf 已写入"

cat > package/base-files/files/etc/sysctl.d/99-network.conf << 'EOF'
net.core.netdev_max_backlog=65536
net.core.netdev_budget=50000
net.ipv4.tcp_mem=262144 524288 786432
net.ipv4.tcp_rmem=4096 87380 6291456
net.ipv4.tcp_wmem=4096 65536 6291456
net.ipv4.tcp_congestion_control=cubic
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_slow_start_after_idle=0
EOF
echo "✓ /etc/sysctl.d/99-network.conf 已写入"

echo "nf_conntrack hashsize=65536" > package/base-files/files/etc/modules.d/99-nf-conntrack-custom
echo "✓ /etc/modules.d/99-nf-conntrack-custom 已写入"

cat > package/base-files/files/etc/hotplug.d/iface/99-conntrack << 'HOTPLUG'
#!/bin/sh
[ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "wan" ] && {
    sleep 2
    echo 262144 > /proc/sys/net/netfilter/nf_conntrack_max
    echo 600 > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established
    echo 30 > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_time_wait
    echo 10 > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_close_wait
    echo 10 > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_fin_wait
    echo 30 > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_syn_recv
    echo 30 > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_syn_sent
    echo 10 > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_last_ack
    echo 10 > /proc/sys/net/netfilter/nf_conntrack_udp_timeout
    echo 30 > /proc/sys/net/netfilter/nf_conntrack_udp_timeout_stream
    echo 5 > /proc/sys/net/netfilter/nf_conntrack_icmp_timeout
    echo 0 > /proc/sys/net/netfilter/nf_conntrack_log_invalid
    echo 1 > /proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal
}
HOTPLUG
chmod +x package/base-files/files/etc/hotplug.d/iface/99-conntrack
echo "✓ /etc/hotplug.d/iface/99-conntrack 已写入"

# ==========================================
# WiFi 配置
# ==========================================
MAC80211_UC="package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"

if [ -f "$MAC80211_UC" ]; then
    echo "找到 mac80211.uc，修改 WiFi 默认配置..."
    
    sed -i "s/set \${si}\.disabled='\${defaults ? 0 : 1}'/set \${si}.disabled='0'/g" "$MAC80211_UC"
    sed -i 's/"OpenWrt"/"Wax206"/g' "$MAC80211_UC"
    sed -i "s|set \${s}.country=.*|set \${s}.country='JP'|g" "$MAC80211_UC"
    sed -i "/set \${s}.country=/a set \${s}.txpower='28'" "$MAC80211_UC"
    
    echo "✓ WiFi 默认启用"
    echo "✓ SSID 改为 Wax206"
    echo "✓ 国家代码 JP，功率 28"
else
    echo "警告: 未找到 $MAC80211_UC"
    find . -name "mac80211.uc" -type f 2>/dev/null
fi

echo "=========================================="
echo "DIY 配置完成！"
echo "=========================================="
