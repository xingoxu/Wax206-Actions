#!/bin/bash

Dev=$1
BUILD_DIR=${2:-$1}

echo "=========================================="
echo "DIY Part2 - 设备: $Dev"
echo "BUILD_DIR: $BUILD_DIR"
echo "=========================================="

echo "目标目录: $BUILD_DIR"

if [ ! -d "$BUILD_DIR" ]; then
    echo "错误: 目录 $BUILD_DIR 不存在"
    ls -la
    exit 1
fi

# ========== 添加自定义插件（必须在 cd 之前执行）==========
echo ">>> 添加自定义插件 luci-app-devicemaster..."

if [ -d "wax206/packages/luci-app-devicemaster" ]; then
    cp -r wax206/packages/luci-app-devicemaster "$BUILD_DIR/package/"
    echo "✓ 插件已复制到 $BUILD_DIR/package/luci-app-devicemaster"
else
    echo "⚠ 警告: wax206/packages/luci-app-devicemaster 不存在，跳过插件安装"
fi

cd "$BUILD_DIR" || exit 1
echo "进入目录: $(pwd)"

# ========== 安装插件到 feeds ==========
if [ -d "package/luci-app-devicemaster" ]; then
    ./scripts/feeds update luci >/dev/null 2>&1
    ./scripts/feeds install -a -p luci >/dev/null 2>&1
    echo "✓ luci-app-devicemaster feeds 安装完成"
fi

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

# AP 不保留独立的逻辑 WAN/WAN6 接口。
delete network.wan
delete network.wan6

# DHCP 由上级路由器提供，本机不发放 IPv4/IPv6 地址，也不发送 RA。
set dhcp.lan.ignore='1'
set dhcp.lan.dhcpv4='disabled'
set dhcp.lan.dhcpv6='disabled'
set dhcp.lan.ra='disabled'
set dhcp.lan.ndp='disabled'
EOF

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

exit 0
APMODE

chmod +x package/base-files/files/etc/uci-defaults/99-ap-mode
echo "✓ AP 模式：管理 IP 192.168.1.32，网关 192.168.1.1"
echo "✓ LAN DNS：1.1.1.1、8.8.8.8"
echo "✓ 物理 WAN 口将并入 br-lan"
echo "✓ DHCPv4、DHCPv6、IPv6 RA 和 NDP 已关闭"

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
