#!/usr/bin/env bash
#
# customize.sh —— 小米 CR6608 定制补丁脚本（幂等 / 耐上游变化 / 万用）
#
# 运行位置：OpenWrt 源码树根目录（即同步下来的上游源码，如 /workdir/openwrt）
# 调用方式：$GITHUB_WORKSPACE/scripts/custom/customize.sh [custom目录]
#
# 设计原则（为了「上游怎么变都能一直用」）：
#   1. 绝不修改本 CI 仓库里的主线文件，所有改动只发生在源码树里（每次都是新克隆，天然干净）；
#   2. 所有写操作幂等，可重复执行；所有删除操作先判断存在性，缺失不报错；
#   3. 外部仓库一律「探测分支 + 失败重试」，上游把默认分支从 master 改成 main 也不会中断；
#   4. 软件包清单集中在 custom/packages.seed，增删包不用改脚本；
#   5. 机型白/黑名单集中在 custom/devices.include / devices.exclude；
#   6. 关键项（argon 主题、kmod-tun）缺失才报错；其余第三方插件缺失只告警并自动降级，
#      绝不因为某个上游插件挂了就把整条流水线打断；
#   7. 按目标架构做兼容性过滤：不支持的插件自动跳过，而不是编译到一半炸掉。
#
set -Eeuo pipefail

CUSTOM_DIR="${1:-${CUSTOM_DIR:-${GITHUB_WORKSPACE:-$PWD}/custom}}"
WORKSPACE="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# 主线配置：CI 工作区里 .config 的副本（改它不会提交回仓库）
MAIN_CONFIG="${MAIN_CONFIG:-$PWD/.config}"
OUT_DIR="${OUT_DIR:-$WORKSPACE/ci-out}"
PLUGIN_INFO_FILE="${PLUGIN_INFO_FILE:-$OUT_DIR/${ARTIFACT_PREFIX:-CR6608}.plugins.md}"
THIRD_PARTY_SOURCES_FILE="${THIRD_PARTY_SOURCES_FILE:-$OUT_DIR/third-party-sources.txt}"
SOURCE_TMP="${SOURCE_TMP:-$PWD/.custom-src}"

DEFAULT_THEME="${DEFAULT_THEME:-argon}"
EASYTIER_VARIANT="${EASYTIER_VARIANT:-noweb}"   # noweb = 官方预编译（快）；full = 源码编译（慢）
ZEROTIER_SOURCE="${ZEROTIER_SOURCE:-mwarning}"  # mwarning = 新版包；feeds = 用 feeds 自带

log()  { printf '[custom] %s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*"; }
die()  { printf '::error::%s\n' "$*" >&2; exit 1; }

mkdir -p "$OUT_DIR" "$SOURCE_TMP"
[ -s "$THIRD_PARTY_SOURCES_FILE" ] || printf 'Repository\tBranch\tCommit\tLocalDate\n' > "$THIRD_PARTY_SOURCES_FILE"

############################ 通用工具 ############################

# 探测外部仓库实际存在的分支（按候选顺序），上游改分支名也不会失败
detect_branch() {
  local repo_url="$1"
  shift
  local candidate
  for candidate in "$@"; do
    if git ls-remote --exit-code --heads "$repo_url" "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

git_date() { git -C "$1" log -1 --format=%cs 2>/dev/null || true; }

record_revision() {
  local repo_url="$1" branch="$2" dir="$3" commit
  commit="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
  grep -Fq -- "$repo_url	$branch	$commit" "$THIRD_PARTY_SOURCES_FILE" 2>/dev/null && return 0
  printf '%s\t%s\t%s\t%s\n' "$repo_url" "$branch" "${commit:-unknown}" "$(git_date "$dir")" >> "$THIRD_PARTY_SOURCES_FILE"
}

# fetch_repo <url> <临时目录> <候选分支...>
fetch_repo() {
  local url="$1" dest="$2"
  shift 2
  local branch attempt
  branch="$(detect_branch "$url" "$@")" || { warn "分支探测失败（候选: $*）: $url"; return 1; }
  rm -rf "$dest"
  for ((attempt = 1; attempt <= 3; attempt++)); do
    if git clone --depth=1 --no-tags --single-branch --branch "$branch" "$url" "$dest" >/dev/null 2>&1; then
      record_revision "$url" "$branch" "$dest"
      log "已获取 $url [$branch] @ $(git -C "$dest" rev-parse --short HEAD)"
      return 0
    fi
    warn "克隆失败，重试 ${attempt}/3: $url"
    sleep $((attempt * 5))
  done
  warn "克隆最终失败: $url"
  return 1
}

# config_set <config文件> <符号> <y|n|m>
config_set() {
  local file="$1" symbol="$2" value="$3"
  [ -f "$file" ] || { warn "配置文件不存在，跳过: $file"; return 0; }
  if grep -Eq "^${symbol}=|^#[[:space:]]+${symbol}[[:space:]]+is[[:space:]]+not[[:space:]]+set" "$file"; then
    sed -i -E "s|^(${symbol})=.*|\1=${value}|; s|^#[[:space:]]+(${symbol})[[:space:]]+is[[:space:]]+not[[:space:]]+set|\1=${value}|" "$file"
  else
    printf '%s=%s\n' "$symbol" "$value" >> "$file"
  fi
}

# 目录存在就删，不存在也不报错
safe_rm() {
  local target
  for target in "$@"; do
    rm -rf "$target" 2>/dev/null || true
  done
}

# 目标架构：CONFIG_TARGET_ARCH_PACKAGES="mipsel_24kc" -> mipsel
target_arch() {
  local v
  v="$(grep -m1 -E '^CONFIG_TARGET_ARCH_PACKAGES=' "$MAIN_CONFIG" 2>/dev/null \
       | sed -E 's/^[^=]*=//; s/"//g; s/^[[:space:]]+//')"
  printf '%s\n' "${v%%_*}"
}
ARCH_NAME="$(target_arch)"
[ -n "$ARCH_NAME" ] || ARCH_NAME=unknown
log "目标架构: ${ARCH_NAME}（由 CONFIG_TARGET_ARCH_PACKAGES 推导）"

############################ 1. 定制清单写入配置副本 ############################

log "应用定制清单: ${CUSTOM_DIR}/packages.seed"
if [ -f "${CUSTOM_DIR}/packages.seed" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%$'\r'}"
    case "$line" in
      '') continue ;;
    esac
    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      # 只有 "# CONFIG_xxx is not set" 是有效指令，其余说明文字静默跳过
      if [[ "$line" =~ ^#[[:space:]]+(CONFIG_[A-Za-z0-9_.-]+)[[:space:]]+is[[:space:]]+not[[:space:]]+set ]]; then
        config_set "$MAIN_CONFIG" "${BASH_REMATCH[1]}" n
      fi
      continue
    fi
    if [[ "$line" =~ ^(CONFIG_[A-Za-z0-9_.-]+)=(y|n|m)$ ]]; then
      config_set "$MAIN_CONFIG" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    elif [[ "$line" =~ ^(CONFIG_[A-Za-z0-9_.-]+)=(.*)$ ]]; then
      config_set "$MAIN_CONFIG" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
      warn "无法解析的定制行，已忽略: $line"
    fi
  done < "${CUSTOM_DIR}/packages.seed"
else
  warn "未找到 ${CUSTOM_DIR}/packages.seed，跳过清单应用"
fi

# 硬需求：不管 seed 怎么写都强制生效（这些缺了固件就不符合要求）
config_set "$MAIN_CONFIG" CONFIG_PACKAGE_luci-theme-argon y
config_set "$MAIN_CONFIG" CONFIG_PACKAGE_kmod-tun y
config_set "$MAIN_CONFIG" CONFIG_PACKAGE_luci-theme-aurora n
config_set "$MAIN_CONFIG" CONFIG_PACKAGE_luci-app-aurora-config n

############################ 2. 移除 Aurora 主题 ############################
# CR6608 当前用的是 argon，正常情况下这里没有可删的；
# 保留该逻辑是为了「上游/别人换成 aurora 时也能一直用」。

log "确保 Aurora 主题及其配置插件不存在"
safe_rm \
  feeds/luci/themes/luci-theme-aurora \
  feeds/luci/applications/luci-app-aurora-config \
  package/feeds/luci/luci-theme-aurora \
  package/feeds/luci/luci-app-aurora-config \
  package/luci-theme-aurora \
  package/luci-app-aurora-config

while IFS= read -r leftover; do
  safe_rm "$leftover"
done < <(find package feeds -maxdepth 4 -type d \( -name 'luci-theme-aurora' -o -name 'luci-app-aurora-config' \) -print 2>/dev/null || true)

############################ 3. 拉取第三方软件包（带架构兼容性过滤）############################

log "拉取第三方软件包（架构: ${ARCH_NAME}）"

# --- EasyTier（含 luci-app-easytier）---
ez_dir="$SOURCE_TMP/easytier"
if fetch_repo https://github.com/EasyTier/luci-app-easytier.git "$ez_dir" main master; then
  ez_variant_dir="$ez_dir/easytier-${EASYTIER_VARIANT}"
  ez_pkg_mk="$ez_variant_dir/Makefile"
  # 兼容性过滤：包声明的架构白名单里必须有本架构，且 Makefile 里有对应的 APP_ARCH 映射
  if [ -f "$ez_pkg_mk" ] \
     && grep -qE "@\([^)]*\b${ARCH_NAME}\b[^)]*\)" "$ez_pkg_mk" \
     && grep -qE "ifeq[[:space:]]*\(\\\$\(ARCH\),${ARCH_NAME}\)" "$ez_pkg_mk"; then
    safe_rm package/easytier
    mkdir -p package/easytier
    cp -a "$ez_dir/." package/easytier/
    safe_rm package/easytier/.git package/easytier/.github
    if [ "$EASYTIER_VARIANT" = "noweb" ]; then
      safe_rm package/easytier/easytier
      config_set "$MAIN_CONFIG" CONFIG_PACKAGE_easytier-noweb y
      config_set "$MAIN_CONFIG" CONFIG_PACKAGE_easytier n
    else
      safe_rm package/easytier/easytier-noweb
      config_set "$MAIN_CONFIG" CONFIG_PACKAGE_easytier y
      config_set "$MAIN_CONFIG" CONFIG_PACKAGE_easytier-noweb n
    fi
    config_set "$MAIN_CONFIG" CONFIG_PACKAGE_luci-app-easytier y
    log "  已加入 EasyTier（${EASYTIER_VARIANT}，支持 ${ARCH_NAME}）"
  else
    warn "EasyTier 不支持当前架构 ${ARCH_NAME}（或包结构变化），本次跳过"
    config_set "$MAIN_CONFIG" CONFIG_PACKAGE_easytier-noweb n
    config_set "$MAIN_CONFIG" CONFIG_PACKAGE_easytier n
    config_set "$MAIN_CONFIG" CONFIG_PACKAGE_luci-app-easytier n
  fi
else
  warn "EasyTier 获取失败，本次编译将不含 EasyTier（ZeroTier 仍可用）"
  config_set "$MAIN_CONFIG" CONFIG_PACKAGE_easytier-noweb n
  config_set "$MAIN_CONFIG" CONFIG_PACKAGE_luci-app-easytier n
fi

# --- ZeroTier（可选：用 mwarning 维护的新版包替换 feeds 旧版；失败自动回退）---
zt_dir="$SOURCE_TMP/zerotier"
zt_backup="feeds/packages/net/zerotier.cifeedbackup"
if [ "$ZEROTIER_SOURCE" = "mwarning" ]; then
  if fetch_repo https://github.com/mwarning/zerotier-openwrt.git "$zt_dir" master main; then
    if [ -d "$zt_dir/zerotier" ] && [ -f "$zt_dir/zerotier/Makefile" ]; then
      # 先把 feeds 版备份起来，方便后面校验失败时回退
      if [ -d feeds/packages/net/zerotier ] && [ ! -d "$zt_backup" ]; then
        cp -a feeds/packages/net/zerotier "$zt_backup" 2>/dev/null || true
      fi
      safe_rm feeds/packages/net/zerotier package/feeds/packages/zerotier package/zerotier
      mv "$zt_dir/zerotier" package/zerotier
      printf 'ZEROTIER_BACKUP=%s\n' "$zt_backup" > "$OUT_DIR/zerotier-fallback.env"
      config_set "$MAIN_CONFIG" CONFIG_PACKAGE_zerotier y
      config_set "$MAIN_CONFIG" CONFIG_PACKAGE_luci-app-zerotier y
      log "  已用 mwarning/zerotier-openwrt 替换 feeds 版 zerotier"
    else
      warn "zerotier 包目录结构变化，未找到 zerotier/Makefile，回退 feeds 版"
      config_set "$MAIN_CONFIG" CONFIG_PACKAGE_zerotier y
    fi
  else
    warn "ZeroTier 新版包获取失败，回退 feeds 自带版本"
    config_set "$MAIN_CONFIG" CONFIG_PACKAGE_zerotier y
    config_set "$MAIN_CONFIG" CONFIG_PACKAGE_luci-app-zerotier y
  fi
fi
if [ "$ZEROTIER_SOURCE" = "feeds" ]; then
  config_set "$MAIN_CONFIG" CONFIG_PACKAGE_zerotier y
  config_set "$MAIN_CONFIG" CONFIG_PACKAGE_luci-app-zerotier y
  log "  按配置使用 feeds 自带 zerotier"
fi

# --- ddns-go ---
ddns_dir="$SOURCE_TMP/ddns-go"
if fetch_repo https://github.com/sirpdboy/luci-app-ddns-go.git "$ddns_dir" main master; then
  safe_rm feeds/packages/net/ddns-go package/feeds/packages/ddns-go package/ddns-go
  safe_rm feeds/luci/applications/luci-app-ddns-go package/feeds/luci/luci-app-ddns-go package/luci-app-ddns-go
  added=0
  if [ -d "$ddns_dir/ddns-go" ]; then mv "$ddns_dir/ddns-go" package/ddns-go; added=1; fi
  if [ -d "$ddns_dir/luci-app-ddns-go" ]; then mv "$ddns_dir/luci-app-ddns-go" package/luci-app-ddns-go; added=1; fi
  if [ "$added" -eq 1 ]; then
    config_set "$MAIN_CONFIG" CONFIG_PACKAGE_ddns-go y
    config_set "$MAIN_CONFIG" CONFIG_PACKAGE_luci-app-ddns-go y
    log "  已加入 ddns-go"
  else
    warn "ddns-go 仓库结构变化，未找到子目录，本次跳过"
  fi
else
  warn "ddns-go 获取失败，本次编译将不含 ddns-go"
fi

# --- iStore：4 个子包放到 package/ 顶层（与参考项目已验证的落位一致）---
istore_src="$SOURCE_TMP/istore"
if fetch_repo https://github.com/linkease/istore.git "$istore_src" main master; then
  istore_ok=1
  for pkg in luci-app-store luci-lib-taskd luci-lib-xterm taskd; do
    if [ -d "$istore_src/luci/$pkg" ]; then
      safe_rm "package/$pkg"
      cp -a "$istore_src/luci/$pkg" "package/$pkg"
      # 去掉本构建里无法满足的依赖：libuci-lua(24.10 已移除) / tar / mount-utils(本 profile 未选)
      # 这些会生成 select PACKAGE_xxx，目标未定义时会让该包在 defconfig 阶段被静默丢弃
      find "package/$pkg" -name Makefile -exec sed -i -E 's/[[:space:]]*\+(libuci-lua|tar|mount-utils)//g' {} + 2>/dev/null || true
      log "  已放入 package/$pkg"
    else
      warn "istore 缺少子包 luci/$pkg"; istore_ok=0
    fi
  done
  if [ "$istore_ok" -eq 1 ]; then
    for sym in luci-app-store luci-lib-taskd luci-lib-xterm taskd luci-compat luci-lua-runtime; do
      config_set "$MAIN_CONFIG" "CONFIG_PACKAGE_$sym" y
    done
    log "  iStore 已加入"
  fi
else
  warn "iStore 获取失败，本次编译将不含 iStore"
fi

# --- luci-app-wechatpush（微信 / Telegram / 邮件 推送通知）---
wxp_dir="$SOURCE_TMP/wechatpush"
if fetch_repo https://github.com/tty228/luci-app-wechatpush.git "$wxp_dir" master main; then
  safe_rm package/luci-app-wechatpush
  mkdir -p package/luci-app-wechatpush
  cp -a "$wxp_dir/." package/luci-app-wechatpush/
  rm -rf package/luci-app-wechatpush/.git package/luci-app-wechatpush/.github
  config_set "$MAIN_CONFIG" CONFIG_PACKAGE_luci-app-wechatpush y
  for dep in iputils-arping curl jq bash luci-lua-runtime luci-compat; do
    config_set "$MAIN_CONFIG" "CONFIG_PACKAGE_$dep" y
  done
  log "  已加入 luci-app-wechatpush"
else
  warn "wechatpush 获取失败，本次编译将不含该插件"
fi

############################ 3.5 记录各插件版本与上游更新时间 ############################
# 生成 markdown 表，随固件一起打包，并由 Release 脚本写入发布说明。

pkg_ver() {
  local f v
  for f in "$@"; do
    [ -f "$f" ] || continue
    v="$(grep -m1 -E '^[[:space:]]*PKG_VERSION[[:space:]]*:?=' "$f" 2>/dev/null | sed -E 's/^[^=]*=[[:space:]]*//' | tr -d ' \r')"
    [ -n "$v" ] || continue
    # 处理 $(or $(X),1.2.3) 这类 make 表达式：取最后一个逗号后的真实版本号
    case "$v" in *'$('*) v="$(printf '%s' "$v" | sed -E 's/.*,([^,()]+)\)[^,()]*$/\1/')" ;; esac
    printf '%s' "$v"; return 0
  done
}

{
  printf '| 插件 | 版本 | 上游最近更新 | 仓库 |\n'
  printf '|---|---|---|---|\n'
} > "$PLUGIN_INFO_FILE"
plugin_row() {
  printf '| %s | %s | %s | %s |\n' "$1" "${2:-(见固件清单)}" "${3:-(未知)}" "$4" >> "$PLUGIN_INFO_FILE"
}

plugin_row "kmod-tun" \
  "$(pkg_ver "$(find package feeds -path '*kmod-tun/Makefile' -print -quit 2>/dev/null || true)")" \
  "(随内核)" "openwrt base"
plugin_row "EasyTier (luci-app-easytier)" \
  "$(pkg_ver "package/easytier/luci-app-easytier/Makefile" "package/easytier/easytier-${EASYTIER_VARIANT}/Makefile")" \
  "$(git_date "$ez_dir")" "https://github.com/EasyTier/luci-app-easytier"
plugin_row "ZeroTier" \
  "$(pkg_ver "package/zerotier/Makefile" "feeds/packages/net/zerotier/Makefile")" \
  "$(git_date "$zt_dir")" "https://github.com/mwarning/zerotier-openwrt"
plugin_row "ddns-go" \
  "$(pkg_ver "package/ddns-go/Makefile")" \
  "$(git_date "$ddns_dir")" "https://github.com/sirpdboy/luci-app-ddns-go"
plugin_row "iStore (luci-app-store)" \
  "$(pkg_ver "package/luci-app-store/Makefile")" \
  "$(git_date "$istore_src")" "https://github.com/linkease/istore"
plugin_row "wechatpush (luci-app-wechatpush)" \
  "$(pkg_ver "package/luci-app-wechatpush/Makefile")" \
  "$(git_date "$wxp_dir")" "https://github.com/tty228/luci-app-wechatpush"
plugin_row "Argon 主题" \
  "$(pkg_ver "feeds/luci/themes/luci-theme-argon/Makefile" "package/luci-theme-argon/Makefile")" \
  "(随 feeds)" "https://github.com/jerrykuku/luci-theme-argon"

log "已生成插件版本信息: $PLUGIN_INFO_FILE"

safe_rm "$SOURCE_TMP"

############################ 4. 默认主题切换为 argon ############################

log "设置默认主题为 ${DEFAULT_THEME}"
theme_switched=0
while IFS= read -r cfg_file; do
  [ -f "$cfg_file" ] || continue
  if grep -q "mediaurlbase" "$cfg_file"; then
    before="$(md5sum "$cfg_file" | awk '{print $1}')"
    sed -i -E "s#(option[[:space:]]+mediaurlbase[[:space:]]+')[^']*(')#\1/luci-static/${DEFAULT_THEME}\2#g" "$cfg_file"
    after="$(md5sum "$cfg_file" | awk '{print $1}')"
    [ "$before" != "$after" ] && { log "  默认主题写入: $cfg_file"; theme_switched=1; }
  fi
done < <(grep -rl "mediaurlbase" feeds package 2>/dev/null || true)

# 兜底：固件首次开机时强制写 uci，即便上面没定位到配置文件也能生效
uci_dir="package/base-files/files/etc/uci-defaults"
mkdir -p "$uci_dir"
cat > "${uci_dir}/99_custom_default_theme" <<EOF
#!/bin/sh
# 由 customize.sh 注入：把 LuCI 默认主题固定为 ${DEFAULT_THEME}
[ -x /bin/uci ] || [ -x /sbin/uci ] || exit 0
[ -f /etc/config/luci ] || touch /etc/config/luci
uci -q set luci.main=core
uci -q set luci.main.mediaurlbase='/luci-static/${DEFAULT_THEME}'
uci -q commit luci
exit 0
EOF
chmod +x "${uci_dir}/99_custom_default_theme"
log "  已注入 uci-defaults 兜底脚本"

if [ ! -d "feeds/luci/themes/luci-theme-argon" ] && [ ! -d "package/luci-theme-argon" ]; then
  die "未找到 luci-theme-argon 源码，无法设置默认主题"
fi
[ "$theme_switched" -eq 1 ] || warn "未在 feeds 中定位到 mediaurlbase 配置文件，已依赖 uci-defaults 兜底"

############################ 5. 机型筛选（白名单优先，其次黑名单）############################

include_file="${CUSTOM_DIR}/devices.include"
if [ -f "$include_file" ] && grep -qvE '^[[:space:]]*(#|$)' "$include_file"; then
  keep_list=()
  while IFS= read -r device || [ -n "$device" ]; do
    device="${device%%$'\r'}"
    case "$device" in
      ''|\#*) continue ;;
    esac
    keep_list+=("$device")
  done < "$include_file"

  if [ "${#keep_list[@]}" -gt 0 ]; then
    # 先把所有机型置为未选中，再逐个放行
    sed -i -E '/^CONFIG_TARGET_DEVICE_/s/^/# /' "$MAIN_CONFIG"
    sed -i -E '/^CONFIG_TARGET_[A-Za-z0-9_]+_DEVICE_/s/^/# /' "$MAIN_CONFIG"
    for device in "${keep_list[@]}"; do
      if grep -qE "^# CONFIG_TARGET_[A-Za-z0-9_]+_DEVICE_${device}=y" "$MAIN_CONFIG"; then
        sed -i -E "/^# (CONFIG_TARGET_[A-Za-z0-9_]+_DEVICE_${device})=y/s/^# //" "$MAIN_CONFIG"
        log "白名单放行机型: $device"
      else
        warn "devices.include 中的 $device 在当前配置里不存在，已忽略"
      fi
    done
  fi
fi

exclude_file="${CUSTOM_DIR}/devices.exclude"
if [ -f "$exclude_file" ] && grep -qvE '^[[:space:]]*(#|$)' "$exclude_file"; then
  while IFS= read -r device || [ -n "$device" ]; do
    device="${device%%$'\r'}"
    case "$device" in
      ''|\#*) continue ;;
    esac
    before_count="$(grep -cE "^CONFIG_TARGET_[A-Za-z0-9_]+_DEVICE_" "$MAIN_CONFIG" || true)"
    sed -i -E "/^CONFIG_TARGET_[A-Za-z0-9_]+_DEVICE_${device}=y/d" "$MAIN_CONFIG"
    after_count="$(grep -cE "^CONFIG_TARGET_[A-Za-z0-9_]+_DEVICE_" "$MAIN_CONFIG" || true)"
    [ "$before_count" != "$after_count" ] && log "已剔除机型: $device"
  done < "$exclude_file"
fi

dev_selected="$(grep -cE '^CONFIG_TARGET_[A-Za-z0-9_]+_DEVICE_.*=y' "$MAIN_CONFIG" || true)"
log "当前选中的机型数量: $dev_selected"
[ "$dev_selected" -gt 0 ] || die "没有任何机型被选中，请检查 ${CUSTOM_DIR}/devices.include"

############################ 6. 刷新索引并自检 ############################

# 强制 make defconfig 重新扫描 package/ 树，保证新加入的包能被识别
safe_rm tmp/.packageinfo tmp/.targetinfo tmp/.packageauxvars

log "定制完成，当前关键项："
grep -E '^CONFIG_PACKAGE_(kmod-tun|luci-theme-argon|luci-app-argon-config|luci-theme-aurora|zerotier|luci-app-zerotier|easytier|easytier-noweb|luci-app-easytier|ddns-go|luci-app-ddns-go|luci-app-store|luci-app-wechatpush|xray-core|v2ray-core)=' "$MAIN_CONFIG" || true
