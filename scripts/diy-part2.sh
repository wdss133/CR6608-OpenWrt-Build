#!/bin/bash
# DIY第二阶段：自定义默认配置

# ==========================================================================
# 修复 SSL 后端冲突（关键，否则编译一定失败在 package/install 阶段）
#
# 报错原文：
#   check_data_file_clashes: Package libustream-openssl20201210 wants to
#   install file .../root-ramips/lib/libustream-ssl.so
#   But that file is already provided by package libustream-mbedtls20201210
#   opkg_install_cmd: Cannot install package libustream-openssl20201210.
#   make[2]: *** [package/Makefile:99: package/install] Error 255
#
# 原因：libustream-ssl 的三个变体(openssl / mbedtls / wolfssl)都会安装同一个
# 文件 /lib/libustream-ssl.so，Makefile 中已声明 CONFLICTS，只能存在一个。
# 而 immortalwrt 的 include/target.mk 把 libustream-openssl 写进了
# DEFAULT_PACKAGES，会被强制置为 =y；而 luci-ssl 与 wpad-basic-mbedtls 又会
# 拉入 libustream-mbedtls，于是两个变体同时被选中，安装阶段必然撞文件。
#
# 解决：把 libustream-openssl 从 DEFAULT_PACKAGES 中删除，
#      配合 .config 中显式声明的 CONFIG_PACKAGE_libustream-mbedtls=y，
#      使全局只有 mbedtls 一个变体（体积也最小，对 CR6608 的 Flash 更友好）。
# ==========================================================================
if [ -f include/target.mk ]; then
  sed -i '/libustream-openssl/d' include/target.mk
  echo "--- include/target.mk 中 libustream 相关行 ---"
  grep -n 'libustream' include/target.mk || echo "(已无 libustream 默认项)"
else
  echo "警告：未找到 include/target.mk，跳过 SSL 后端修复"
fi

# 设置默认IP为192.168.1.1
sed -i 's/192.168.1.1/192.168.1.1/g' package/base-files/files/bin/config_generate

# 设置默认密码为qq3429510
sed -i 's/root::0:0:99999:7:::/root:$1$V4UetPzk$CYXluq4wUazHjmCDBCqXF.:0:0:99999:7:::/g' package/base-files/files/etc/shadow

# 设置主机名
sed -i 's/OpenWrt/CR6608/g' package/base-files/files/bin/config_generate

# 设置时区为上海
sed -i "s/'UTC'/'CST-8'\n        set system.@system[-1].zonename='Asia\/Shanghai'/g" package/base-files/files/bin/config_generate

# 默认开启WiFi
sed -i 's/disabled=1/disabled=0/g' package/kernel/mac80211/files/lib/wifi/mac80211.sh

# 设置默认WiFi名称
sed -i 's/ssid=OpenWrt/ssid=CR6608/g' package/kernel/mac80211/files/lib/wifi/mac80211.sh

# 修改默认主题为Argon
sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile

# 移除默认密码为空（强制设置密码）
sed -i '/CYXluq4wUazHjmCDBCqXF/d' package/lean/default-settings/files/zzz-default-settings 2>/dev/null || true

echo "=================== DIY第二阶段完成 ==================="
echo "默认IP: 192.168.1.1"
echo "默认密码: qq3429510"
echo "默认主题: Argon"
echo "SSL后端: mbedtls（已移除 libustream-openssl 默认项）"
