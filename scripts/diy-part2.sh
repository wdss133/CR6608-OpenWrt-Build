#!/bin/bash
# DIY第二阶段：自定义默认配置

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
