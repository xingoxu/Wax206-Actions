#!/usr/bin/env bash
# ============================================================================
# WAX206 一体化编译脚本
# 整合 pre_clone_action.sh + update.sh + modules/*.sh + build.sh
# ============================================================================

set -o errexit
set -o errtrace
set -o pipefail

error_handler() {
    local line=$1
    local cmd=$2
    echo "Error occurred in script at line: ${line}, command: '${cmd}'"
    exit 1
}
trap 'error_handler "${BASH_LINENO[0]}" "${BASH_COMMAND}"' ERR

# ==================== 自动定位仓库根目录 ====================
# 获取脚本自身所在目录（支持符号链接）
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_SOURCE" ]; do
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
    SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
    [[ "$SCRIPT_SOURCE" != /* ]] && SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"

# 关键修复：判断脚本所在的目录名，回到正确的仓库根目录
SCRIPT_BASENAME="$(basename "$SCRIPT_DIR")"
if [ "$SCRIPT_BASENAME" = "wax206" ] || [ "$SCRIPT_BASENAME" = "wrt_core" ] || [ "$SCRIPT_BASENAME" = "scripts" ] || [ "$SCRIPT_BASENAME" = "bin" ]; then
    REPO_ROOT="$(dirname "$SCRIPT_DIR")"
else
    REPO_ROOT="$SCRIPT_DIR"
fi

# 切换到仓库根目录
cd "$REPO_ROOT" || { echo "Error: Cannot cd to $REPO_ROOT"; exit 1; }
echo ">>> 工作目录: $(pwd)"
echo ">>> REPO_ROOT: $REPO_ROOT"
# ==========================================================

# ==================== 全局变量 ====================
Dev=$1
Build_Mod=$2

# 确定 wax206 目录路径（现在在正确的根目录下判断）
if [ -d "wax206" ]; then
    WAX206_PATH="wax206"
elif [ -d "../wax206" ]; then
    WAX206_PATH="../wax206"
else
    echo "Error: wax206 directory not found! (PWD: $(pwd))"
    # 最后尝试从脚本位置搜索
    FOUND_WAX206=$(find "$REPO_ROOT" -maxdepth 2 -type d -name "wax206" | head -1)
    if [ -n "$FOUND_WAX206" ]; then
        WAX206_PATH="$FOUND_WAX206"
        echo "Found wax206 via search: $WAX206_PATH"
    else
        exit 1
    fi
fi

BASE_PATH=$(cd "$WAX206_PATH" && pwd)
echo ">>> BASE_PATH: $BASE_PATH"

CONFIG_FILE="$BASE_PATH/deconfig/$Dev.config"
INI_FILE="$BASE_PATH/compilecfg/$Dev.ini"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Config not found: $CONFIG_FILE"
    exit 1
fi

if [[ ! -f "$INI_FILE" ]]; then
    echo "INI file not found: $INI_FILE"
    exit 1
fi

# ==================== 工具函数 ====================
read_ini_by_key() {
    local key=$1
    awk -F"=" -v key="$key" '$1 == key {print $2}' "$INI_FILE"
}

REPO_URL=$(read_ini_by_key "REPO_URL")
REPO_BRANCH=$(read_ini_by_key "REPO_BRANCH")
REPO_BRANCH=${REPO_BRANCH:-main}
BUILD_DIR=$(read_ini_by_key "BUILD_DIR")
COMMIT_HASH=$(read_ini_by_key "COMMIT_HASH")
COMMIT_HASH=${COMMIT_HASH:-none}

FEEDS_CONF="feeds.conf.default"
GOLANG_REPO="https://github.com/sbwml/packages_lang_golang"
GOLANG_BRANCH="26.x"
THEME_SET="argon"
LAN_ADDR="192.168.31.1"

# ==================== [pre_clone_action.sh] 克隆源码 ====================
clone_source() {
    echo "=== 克隆固件代码 ==="
    echo "$REPO_URL $REPO_BRANCH"
    echo "$REPO_URL/$REPO_BRANCH" >"$BASE_PATH/../repo_flag"

    # 检查是否存在有效的 git 仓库（必须有 .git 目录）
    if [[ -d "$BASE_PATH/../action_build/.git" ]]; then
        echo "action_build 已存在有效的 git 仓库，跳过克隆"
    else
        # 目录存在但没有 .git（可能是缓存恢复的 staging_dir），需要重新克隆
        if [[ -d "$BASE_PATH/../action_build" ]]; then
            echo "action_build 目录存在但缺少 .git，保留缓存后重新克隆"
            # 将缓存目录移动到临时位置
            mkdir -p "$BASE_PATH/../cache_temp"
            if [[ -d "$BASE_PATH/../action_build/staging_dir" ]]; then
                mv "$BASE_PATH/../action_build/staging_dir" "$BASE_PATH/../cache_temp/"
            fi
            if [[ -d "$BASE_PATH/../action_build/.ccache" ]]; then
                mv "$BASE_PATH/../action_build/.ccache" "$BASE_PATH/../cache_temp/"
            fi
            # 清空 action_build 目录
            rm -rf "$BASE_PATH/../action_build"
        fi
        
        if ! git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$BASE_PATH/../action_build"; then
            echo "错误：克隆仓库 $REPO_URL 失败" >&2
            exit 1
        fi

        # 恢复缓存目录
        if [[ -d "$BASE_PATH/../cache_temp/staging_dir" ]]; then
            mv "$BASE_PATH/../cache_temp/staging_dir" "$BASE_PATH/../action_build/"
        fi
        if [[ -d "$BASE_PATH/../cache_temp/.ccache" ]]; then
            mv "$BASE_PATH/../cache_temp/.ccache" "$BASE_PATH/../action_build/"
        fi
        rm -rf "$BASE_PATH/../cache_temp"

        # 移除国内下载源
        local mirrors_file="$BASE_PATH/../action_build/scripts/projectsmirrors.json"
        if [ -f "$mirrors_file" ]; then
            sed -i '/.cn\//d; /tencent/d; /aliyun/d' "$mirrors_file"
        fi
    fi

    # 克隆完成后，强制使用 action_build 作为构建目录
    BUILD_DIR="$BASE_PATH/../action_build"
    # 转换为绝对路径
    BUILD_DIR=$(cd "$BUILD_DIR" && pwd)
    echo "BUILD_DIR 设置为: $BUILD_DIR"
}

# ==================== [modules/general.sh] 通用准备 ====================
clone_repo() {
    # clone_source 已完成克隆，这里只验证目录存在
    if [[ ! -d "$BUILD_DIR" ]]; then
        echo "错误：构建目录 $BUILD_DIR 不存在" >&2
        exit 1
    fi
    echo "构建目录已就绪: $BUILD_DIR"
}

clean_up() {
    if [[ ! -d "$BUILD_DIR" ]]; then
        echo "Build directory $BUILD_DIR does not exist"
        return
    fi
    cd "$BUILD_DIR"
    if [[ -f ".config" ]]; then
        \rm -f ".config"
    fi
    if [[ -d "tmp" ]]; then
        \rm -rf "tmp"
    fi
    if [[ -d "logs" ]]; then
        find logs -type f -delete 2>/dev/null || true
    fi
    if [[ -d "feeds" ]]; then
        ./scripts/feeds clean
    fi
    # 刷新 staging_dir 中的 stamp 文件时间戳，保持缓存有效性
    if [[ -d "staging_dir" ]]; then
        echo "刷新 staging_dir 中的 stamp 文件时间戳..."
        find staging_dir -type d -name "stamp" -not -path "*target*" | while read -r dir; do
            find "$dir" -type f -exec touch {} +
        done
    fi
    mkdir -p "tmp"
    echo "1" >"tmp/.build"
    cd - > /dev/null
}

reset_feeds_conf() {
    cd "$BUILD_DIR"
    # 确保远程仓库正确指向 OpenWrt 源码仓库
    # GitHub Actions 环境可能会覆盖 origin
    local current_origin=$(git remote get-url origin 2>/dev/null || echo "")
    if [[ "$current_origin" != "$REPO_URL" ]]; then
        echo "修正 origin 远程仓库: $current_origin -> $REPO_URL"
        git remote set-url origin "$REPO_URL" 2>/dev/null || git remote add origin "$REPO_URL"
    fi
    # 浅克隆(--depth 1)不会创建远程分支引用(如 origin/main)
    # 先 fetch 建立 origin/$REPO_BRANCH 引用，再 reset
    git fetch origin "$REPO_BRANCH" --depth 1
    git reset --hard "origin/$REPO_BRANCH"
    # 使用 -e 排除缓存目录，避免删除 staging_dir 和 .ccache
    git clean -f -d -e staging_dir -e .ccache -e tmp
    if [[ "$COMMIT_HASH" != "none" ]]; then
        git checkout "$COMMIT_HASH"
    fi
    # 重置源码后，刷新 staging_dir 中的 stamp 文件时间戳，保持缓存有效性
    if [[ -d "staging_dir" ]]; then
        echo "重置源码后刷新 staging_dir 中的 stamp 文件时间戳..."
        find staging_dir -type d -name "stamp" -not -path "*target*" | while read -r dir; do
            find "$dir" -type f -exec touch {} +
        done
    fi
    cd - > /dev/null
}

# ==================== [modules/feeds.sh] Feeds 管理 ====================
update_feeds() {
    cd "$BUILD_DIR"
    local FEEDS_PATH="$BUILD_DIR/$FEEDS_CONF"
    if [[ -f "$BUILD_DIR/feeds.conf" ]]; then
        FEEDS_PATH="$BUILD_DIR/feeds.conf"
    fi
    sed -i '/^#/d' "$FEEDS_PATH"
    sed -i '/packages_ext/d' "$FEEDS_PATH"
    
    # 注意：不添加 small 源，它包含与官方源冲突的核心包（如 openssl 修改版）
    # 只添加 kenzok 源（用于 argon 主题）
    if ! grep -q "kenzok" "$FEEDS_PATH"; then
        [ -z "$(tail -c 1 "$FEEDS_PATH")" ] || echo "" >>"$FEEDS_PATH"
        echo "src-git kenzok https://github.com/kenzok8/openwrt-packages.git;master" >>"$FEEDS_PATH"
    fi

    if ! grep -q "openwrt-passwall2" "$FEEDS_PATH"; then
        [ -z "$(tail -c 1 "$FEEDS_PATH")" ] || echo "" >>"$FEEDS_PATH"
        echo "src-git passwall2 https://github.com/Openwrt-Passwall/openwrt-passwall2.git;main" >>"$FEEDS_PATH"
    fi

    if ! grep -q "openwrt-passwall-packages" "$FEEDS_PATH"; then
        [ -z "$(tail -c 1 "$FEEDS_PATH")" ] || echo "" >>"$FEEDS_PATH"
        echo "src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main" >>"$FEEDS_PATH"
    fi

    if [ ! -f "$BUILD_DIR/include/bpf.mk" ]; then
        touch "$BUILD_DIR/include/bpf.mk"
    fi

    # 选择性更新 feeds，避免扫描有问题的第三方源的所有包
    # 问题：kenzok 源中部分包的 Makefile 格式有问题
    # 解决：只更新官方源和已知正常的自定义源，第三方源单独处理
    
    # 更新官方 feeds（这些源的 Makefile 格式正常）
    ./scripts/feeds update base packages luci routing telephony
    
    # 更新 Passwall2 及其官方依赖源
    for feed in passwall_packages passwall2; do
        ./scripts/feeds update "$feed" 2>/dev/null || echo "Warning: $feed update failed"
    done
    
    # 对于有问题的第三方源，只克隆但不扫描所有包
    # 后续在 install_feeds 中选择性安装需要的包
    for feed in kenzok; do
        if [ ! -d "$BUILD_DIR/feeds/$feed" ]; then
            echo "克隆 $feed 源（跳过 Makefile 扫描）..."
            # 手动克隆，不通过 feeds update
            mkdir -p "$BUILD_DIR/feeds/$feed"
            case "$feed" in
                kenzok)
                    git clone --depth 1 https://github.com/kenzok8/openwrt-packages.git "$BUILD_DIR/feeds/$feed" 2>/dev/null || true ;;
            esac
        fi
    done
    
    cd - > /dev/null
}

install_feeds() {
    cd "$BUILD_DIR"
    ./scripts/feeds update -i
    
    # 安装官方 feeds
    for feed in base packages luci routing telephony; do
        if [ -d "$BUILD_DIR/feeds/$feed" ]; then
            ./scripts/feeds install -f -ap "$feed" || echo "Warning: $feed install failed"
        fi
    done
    
    # 安装 Passwall2 官方依赖
    if [ -d "$BUILD_DIR/feeds/passwall_packages" ]; then
        ./scripts/feeds install -f -a -p passwall_packages || echo "Warning: Passwall2 dependencies install failed"
    fi

    # 安装 Passwall2
    if [ -d "$BUILD_DIR/feeds/passwall2" ]; then
        install_passwall2 || echo "Warning: Passwall2 install failed"
    fi
    
    # 对于有问题的第三方源，手动复制需要的包到 package 目录
    # 这样可以绕过 feeds install 的 Makefile 扫描
    
    # kenzok 源：只复制 argon 主题相关包
    if [ -d "$BUILD_DIR/feeds/kenzok" ]; then
        echo "手动安装 kenzok 源中的 argon 主题..."
        for pkg in luci-theme-argon luci-app-argon-config; do
            if [ -d "$BUILD_DIR/feeds/kenzok/$pkg" ]; then
                cp -r "$BUILD_DIR/feeds/kenzok/$pkg" "$BUILD_DIR/package/" 2>/dev/null || true
                echo "已复制: $pkg"
            fi
        done
    fi
    
    cd - > /dev/null
}

# ==================== [modules/packages.sh] 包管理 ====================
update_golang() {
    cd "$BUILD_DIR"
    if [[ -d ./feeds/packages/lang/golang ]]; then
        echo "正在更新 golang 软件包..."
        \rm -rf ./feeds/packages/lang/golang
        if ! git clone --depth 1 -b "$GOLANG_BRANCH" "$GOLANG_REPO" ./feeds/packages/lang/golang; then
            echo "错误：克隆 golang 仓库 $GOLANG_REPO 失败" >&2
            exit 1
        fi
    fi
    cd - > /dev/null
}

install_fichenx() {
    cd "$BUILD_DIR"
    ./scripts/feeds install -p fichenx -f luci-app-argon-config luci-theme-design luci-app-design-config luci-app-watchcat-plus luci-app-wol luci-app-timecontrol \
        xray-core xray-plugin dns2tcp dns2socks haproxy hysteria \
        naiveproxy shadowsocks-rust sing-box v2ray-core v2ray-geodata geoview v2ray-plugin \
        tuic-client chinadns-ng ipt2socks tcping trojan-plus simple-obfs shadowsocksr-libev \
        v2dat mosdns luci-app-mosdns adguardhome luci-app-adguardhome ddns-go \
        luci-app-ddns-go taskd luci-lib-xterm luci-lib-taskd luci-app-store quickstart \
        luci-app-quickstart luci-app-istorex luci-app-cloudflarespeedtest netdata luci-app-netdata \
        lucky luci-app-lucky luci-app-homeproxy luci-app-amlogic nikki luci-app-nikki \
        tailscale luci-app-tailscale oaf open-app-filter luci-app-oaf easytier luci-app-easytier \
        msd_lite luci-app-msd_lite cups luci-app-cupsd
    cd - > /dev/null
}

install_passwall2() {
    cd "$BUILD_DIR"
    ./scripts/feeds install -p passwall2 -f luci-app-passwall2
    cd - > /dev/null
}

remove_attendedsysupgrade() {
    find "$BUILD_DIR/feeds/luci/collections" -name "Makefile" | while read -r makefile; do
        if grep -q "luci-app-attendedsysupgrade" "$makefile"; then
            sed -i "/luci-app-attendedsysupgrade/d" "$makefile"
            echo "Removed luci-app-attendedsysupgrade from $makefile"
        fi
    done
}

fix_rust_compile_error() {
    if [ -f "$BUILD_DIR/feeds/packages/lang/rust/Makefile" ]; then
        sed -i 's/download-ci-llvm=true/download-ci-llvm=false/g' "$BUILD_DIR/feeds/packages/lang/rust/Makefile"
    fi
}

add_ddns_go() {
    local ddns_go_dir="$BUILD_DIR/package/ddns-go"
    local repo_url="https://github.com/sirpdboy/luci-app-ddns-go.git"

    # 移除官方及其它源中的 ddns-go/luci-app-ddns-go，避免包定义冲突
    rm -rf "$BUILD_DIR/feeds/packages/net/ddns-go" 2>/dev/null
    rm -rf "$BUILD_DIR/feeds/luci/applications/luci-app-ddns-go" 2>/dev/null
    rm -rf "$BUILD_DIR/package/feeds/packages/ddns-go" 2>/dev/null
    rm -rf "$BUILD_DIR/package/feeds/luci/luci-app-ddns-go" 2>/dev/null
    rm -rf "$ddns_go_dir" 2>/dev/null

    echo "正在添加 sirpdboy/luci-app-ddns-go..."
    if ! git clone --depth 1 "$repo_url" "$ddns_go_dir"; then
        echo "错误：从 $repo_url 克隆 luci-app-ddns-go 仓库失败" >&2
        exit 1
    fi
}

update_nginx_ubus_module() {
    local makefile_path="$BUILD_DIR/feeds/packages/net/nginx/Makefile"
    if [ -f "$makefile_path" ]; then
        sed -i "s/SOURCE_DATE:=2020-09-06/SOURCE_DATE:=2024-03-02/g; s/SOURCE_VERSION:=b2d7260dcb428b2fb65540edb28d7538602b4a26/SOURCE_VERSION:=564fa3e9c2b04ea298ea659b793480415da26415/g; s/MIRROR_HASH:=515bb9d355ad80916f594046a45c190a68fb6554d6795a54ca15cab8bdd12fda/MIRROR_HASH:=92c9ab94d88a2fe8d7d1e8a15d15cfc4d529fdc357ed96d22b65d5da3dd24d7f/g" "$makefile_path"
        echo "已更新 nginx-mod-ubus 模块"
    fi
}

install_opkg_distfeeds() {
    local emortal_def_dir="$BUILD_DIR/package/emortal/default-settings"
    local distfeeds_conf="$emortal_def_dir/files/99-distfeeds.conf"
    if [ -d "$emortal_def_dir" ] && [ ! -f "$distfeeds_conf" ]; then
        cat <<'EOF' >"$distfeeds_conf"
src/gz openwrt_base https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/base/
src/gz openwrt_luci https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/luci/
src/gz openwrt_packages https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/packages/
src/gz openwrt_routing https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/routing/
src/gz openwrt_telephony https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/telephony/
EOF
        sed -i "/define Package\/default-settings\/install/a\\
\t\$(INSTALL_DIR) \$(1)/etc\n\
\t\$(INSTALL_DATA) ./files/99-distfeeds.conf \$(1)/etc/99-distfeeds.conf\n" "$emortal_def_dir/Makefile"
        sed -i "/exit 0/i\\
[ -f \'/etc/99-distfeeds.conf\' ] && mv \'/etc/99-distfeeds.conf\' \'/etc/opkg/distfeeds.conf\'\n\
sed -ri \'/check_signature/s@^[^#]@#&@\' /etc/opkg.conf\n" "$emortal_def_dir/files/99-default-settings"
    fi
}

# ==================== [build.sh] 构建辅助函数 ====================
remove_uhttpd_dependency() {
    local config_path="$BUILD_DIR/.config"
    local luci_makefile_path="$BUILD_DIR/feeds/luci/collections/luci/Makefile"
    if grep -q "CONFIG_PACKAGE_luci-app-quickfile=y" "$config_path"; then
        if [ -f "$luci_makefile_path" ]; then
            sed -i '/luci-light/d' "$luci_makefile_path"
            echo "Removed uhttpd (luci-light) dependency as luci-app-quickfile (nginx) is enabled."
        fi
    fi
}

apply_config() {
    \cp -f "$CONFIG_FILE" "$BUILD_DIR/.config"
    if grep -qE "(ipq60xx|ipq807x)" "$BUILD_DIR/.config" &&
        ! grep -q "CONFIG_GIT_MIRROR" "$BUILD_DIR/.config"; then
        cat "$BASE_PATH/deconfig/nss.config" >> "$BUILD_DIR/.config"
    fi
}

replace_custom_files() {
    local dts_src dts_dst mk_src mk_dst
    dts_dst="$BUILD_DIR/target/linux/mediatek/dts/mt7622-netgear-wax206.dts"
    mk_dst="$BUILD_DIR/target/linux/mediatek/image/mt7622.mk"
    case "$Dev" in
        "fmwax206")
            echo "=== 应用 FMWAX206 自定义配置（70M 大分区）==="
            dts_src="$BASE_PATH/dts/wax206-70m.dts"; mk_src="$BASE_PATH/mediatek/image/mt7622-70m.mk" ;;
        "gwax206")
            echo "=== 应用 GWAX206 自定义配置（256M 大分区）==="
            dts_src="$BASE_PATH/dts/wax206-256m.dts"; mk_src="$BASE_PATH/mediatek/image/mt7622-256m.mk" ;;
        "gwax206_imm")
            echo "=== 应用 GWAX206 自定义配置（256M 大分区）==="
            dts_src="$BASE_PATH/dts/wax206-256m.dts"; mk_src="$BASE_PATH/mediatek/image/mt7622-256m.mk" ;;
        "wax206")
            echo "=== 使用 WAX206 默认配置（不进行替换）==="; return 0 ;;
        *)
            echo "=== 设备 $Dev 无需自定义 DTS/MK 替换 ==="; return 0 ;;
    esac
    if [[ -f "$dts_src" ]]; then \cp -f "$dts_src" "$dts_dst"; echo "已替换 DTS: $dts_src -> $dts_dst"; else echo "警告: DTS 源文件不存在: $dts_src"; fi
    if [[ -f "$mk_src" ]]; then \cp -f "$mk_src" "$mk_dst"; echo "已替换 MK: $mk_src -> $mk_dst"; else echo "警告: MK 源文件不存在: $mk_src"; fi
}

# ==================== [update.sh main] 源码更新主流程 ====================
run_update() {
    clone_repo
    clean_up
    reset_feeds_conf
    update_feeds
    update_golang
    fix_rust_compile_error
    update_nginx_ubus_module
    install_opkg_distfeeds
    remove_attendedsysupgrade
    install_feeds
    add_ddns_go
}

# ==================== 主流程 ====================
echo "=========================================="
echo "WAX206 一体化编译脚本"
echo "设备: $Dev"
echo "=========================================="

# Step 1: 克隆源码
clone_source

# Step 2: 执行源码更新（原 update.sh 的 main）
run_update

# Step 3: 执行 DIY Part2 配置（调用外部 diy-part2.sh）
echo "=== 执行 DIY Part2 配置 ==="

# diy-part2.sh 内部使用相对路径引用 wax206/packages，需在仓库根目录执行
cd "$REPO_ROOT" || exit 1
bash "$BASE_PATH/diy-part2.sh" "$Dev" "$BUILD_DIR"

# DIY 执行完后回到仓库根目录（后续步骤需要）
cd "$REPO_ROOT" || exit 1


# Step 4: 替换自定义 DTS/MK 文件
replace_custom_files

# Step 5: 应用编译配置
apply_config
remove_uhttpd_dependency

# Step 6: 编译
cd "$BUILD_DIR"
make defconfig

if grep -qE "^CONFIG_TARGET_x86_64=y" "$CONFIG_FILE"; then
    local DISTFEEDS_PATH="$BUILD_DIR/package/emortal/default-settings/files/99-distfeeds.conf"
    if [ -d "${DISTFEEDS_PATH%/*}" ] && [ -f "$DISTFEEDS_PATH" ]; then
        sed -i 's/aarch64_cortex-a53/x86_64/g' "$DISTFEEDS_PATH"
    fi
fi

if [[ "$Build_Mod" == "debug" ]]; then exit 0; fi

TARGET_DIR="$BUILD_DIR/bin/targets"
if [[ -d "$TARGET_DIR" ]]; then
    find "$TARGET_DIR" -type f \( -name "*.bin" -o -name "*.manifest" -o -name "*efi.img.gz" -o -name "*.itb" -o -name "*.img" -o -name "*.ubi" -o -name "*.tar.gz" \) -exec rm -f {} +
fi

make download -j$(($(nproc) * 2))

# 编译时间统计
BUILD_START=$(date +%s)
echo "=============================================="
echo "开始编译: $(date '+%Y-%m-%d %H:%M:%S')"
echo "并行编译数: $(($(nproc) * 2))"
echo "=============================================="

make -j$(($(nproc) * 2))

BUILD_END=$(date +%s)
BUILD_DURATION=$((BUILD_END - BUILD_START))
echo "=============================================="
echo "编译完成: $(date '+%Y-%m-%d %H:%M:%S')"
echo "编译耗时: $((BUILD_DURATION / 3600))小时 $(((BUILD_DURATION % 3600) / 60))分钟 $((BUILD_DURATION % 60))秒"
echo "=============================================="

# Step 7: 收集固件
cd "$BUILD_DIR/bin/packages"
tar -zcvf Packages.tar.gz ./*
cp Packages.tar.gz "$BUILD_DIR/bin/targets/"
cd "$BUILD_DIR"

FIRMWARE_DIR="$BASE_PATH/../firmware"
\rm -rf "$FIRMWARE_DIR"
mkdir -p "$FIRMWARE_DIR"
# factory.img 可用于 NMRP 恢复或网件原厂 Web 升级。
find "$TARGET_DIR" -type f \( -name "*.bin" -o -name "*.img" -o -name "*.itb" -o -name "*.manifest" \) -exec cp -f {} "$FIRMWARE_DIR/" \;

# 缺少新增的 factory 固件时只提示，不中断后续发布。
if ! find "$FIRMWARE_DIR" -maxdepth 1 -type f -name "*netgear_wax206*factory.img" -print -quit | grep -q .; then
    echo "::warning::未找到 WAX206 factory.img（NMRP/网件原厂升级固件），继续执行后续步骤"
fi

# 输出内核版本供workflow使用（容错处理，获取失败不影响编译）
# 临时关闭严格模式，避免管道失败导致脚本退出
set +o pipefail

# 方法1：从 dl 目录获取完整版本号（如 6.18.30）
KVER=""
LINUX_DIR=$(find "$BUILD_DIR/dl" -maxdepth 1 -name "linux-*" -type d 2>/dev/null | sort -r | head -n 1)
if [ -n "$LINUX_DIR" ] && [ -f "$LINUX_DIR/Makefile" ]; then
    # 从内核源码的 Makefile 读取完整版本
    KVER=$(grep -E "^VERSION =|^PATCHLEVEL =|^SUBLEVEL =" "$LINUX_DIR/Makefile" 2>/dev/null | awk '{print $3}' | tr '\n' '.' | sed 's/\.$//')
fi

# 方法2：从 dl 目录名提取（支持 6.18.30 或 6.18 格式）
if [ -z "$KVER" ] && [ -n "$LINUX_DIR" ]; then
    KVER=$(basename "$LINUX_DIR" 2>/dev/null | sed -E 's/linux-([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/')
fi

# 方法3：从 include/kernel-version.mk 获取（OpenWrt 官方方式）
if [ -z "$KVER" ] && [ -f "$BUILD_DIR/include/kernel-version.mk" ]; then
    KVER=$(grep -E "^LINUX_VERSION-" "$BUILD_DIR/include/kernel-version.mk" 2>/dev/null | tail -1 | sed -E 's/.*= *([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/')
fi

# 方法4：从 .config 获取基础版本（无补丁号）
if [ -z "$KVER" ]; then
    KVER=$(grep -oE "^CONFIG_LINUX_[0-9]+_[0-9]+" "$BUILD_DIR/.config" 2>/dev/null | sed -E 's/CONFIG_LINUX_([0-9]+)_([0-9]+)/\1.\2/' | head -1) || true
fi

set -o pipefail
[ -z "$KVER" ] && KVER="Unknown"
echo "$KVER" > "$FIRMWARE_DIR/kernel_version"
echo "内核版本: $KVER"

# if [[ -d "action_build" ]]; then make clean; fi

echo "=========================================="
echo "编译完成！固件已保存到 $FIRMWARE_DIR"
echo "=========================================="
