#!/usr/bin/env bash
# 在 OpenWrt 源码树根目录运行。只使用官方 uci-defaults / board.d 接口，
# 不改 config_generate、DTS、分区表、内核镜像规则或 LuCI 包依赖。
set -Eeuo pipefail

MODE="${1:-full}"
case "$MODE" in
  full|initramfs) ;;
  *) echo "用法: diy-part2.sh [full|initramfs]" >&2; exit 2 ;;
esac

log() { printf '[defaults][%s] %s\n' "$MODE" "$*"; }
[ -f package/base-files/files/bin/config_generate ] || {
  echo "错误：不在 OpenWrt 源码树根目录" >&2; exit 1;
}

# 上游 target.mk 把 libustream-openssl 和基础包写在同一行。旧版脚本整行删除，
# 会连同 base-files/dropbear/fstools 等默认项一起删掉。这里只替换包名。
if grep -q 'libustream-openssl' include/target.mk; then
  sed -i 's/\blibustream-openssl\b/libustream-mbedtls/g' include/target.mk
  log "SSL 后端统一为 mbedtls（未删除同行的其他默认包）"
fi

# 使用官方 board.d 接口只注入系统信息，不改 config_generate 或无线驱动。
mkdir -p package/base-files/files/etc/board.d
cat > package/base-files/files/etc/board.d/99-cr6608-defaults <<'EOF'
#!/bin/sh
. /lib/functions/uci-defaults.sh

board_config_update
json_select system
json_add_string hostname "CR6608"
json_add_string timezone "CST-8"
json_add_string zonename "Asia/Shanghai"
json_select ..

board_config_flush
EOF
chmod +x package/base-files/files/etc/board.d/99-cr6608-defaults

mkdir -p package/base-files/files/etc/uci-defaults
cat > package/base-files/files/etc/uci-defaults/99-cr6608-defaults <<'EOF'
#!/bin/sh
# 官方 boot 已按 config_generate -> wifi config -> uci-defaults 顺序执行，
# 此处只覆盖已生成的配置，不重复调用生成器。
system_id="$(uci -q show system | sed -n "s/^\(system\.[^.]*\)=system$/\1/p" | head -n1)"
if [ -n "$system_id" ]; then
  uci -q set "${system_id}.hostname=CR6608"
  uci -q set "${system_id}.timezone=CST-8"
  uci -q set "${system_id}.zonename=Asia/Shanghai"
  uci -q commit system
fi

# 按实际生成的 wifi-device 设置，不修改 mac80211.sh 或无线驱动。
if [ -s /etc/config/wireless ]; then
  for radio in $(uci -q show wireless | sed -n 's/^\(wireless\.[^.]*\)=wifi-device$/\1/p'); do
    uci -q set "${radio}.disabled=1"
  done
  uci -q commit wireless
fi

uci -q set luci.main=core
uci -q set luci.main.mediaurlbase='/luci-static/argon'
uci -q commit luci

# 只修改 root 行，不覆盖整个 shadow，也不依赖某一版冒号布局。
if grep -q '^root:' /etc/shadow; then
  sed -i 's|^root:[^:]*:|root:$1$V4UetPzk$CYXluq4wUazHjmCDBCqXF.:|' /etc/shadow
  chmod 600 /etc/shadow
fi
exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/99-cr6608-defaults

# 救援盘不混入正式系统的密码和 Argon 默认项；root 无密码，仅限有线直连使用。
if [ "$MODE" = "initramfs" ]; then
  rm -f package/base-files/files/etc/uci-defaults/99-cr6608-defaults
  log "轻量救援盘：基础有线网络 + LuCI + MTD/UBI/sysupgrade；无线关闭；root 无密码"
else
  log "正式系统：保留全部插件；默认 IP 192.168.1.1；主机名 CR6608；时区 Asia/Shanghai"
fi
