#!/bin/bash
# DIY第一阶段：添加第三方feeds

# 添加PassWall feeds
echo "src-git passwall https://github.com/xiaorouji/openwrt-passwall.git;main" >> feeds.conf.default
echo "src-git passwall2 https://github.com/xiaorouji/openwrt-passwall2.git;main" >> feeds.conf.default
echo "src-git passwall_packages https://github.com/xiaorouji/openwrt-passwall-packages.git;main" >> feeds.conf.default

# 添加OpenClash feeds
echo "src-git openclash https://github.com/vernesong/OpenClash.git;master" >> feeds.conf.default

# 添加Argon主题
echo "src-git argon https://github.com/jerrykuku/luci-theme-argon.git;master" >> feeds.conf.default

# 添加DDNSTO
echo "src-git ddnsto https://github.com/linkease/ddnsto-openwrt.git;main" >> feeds.conf.default

# 添加应用商店
echo "src-git appstore https://github.com/linkease/istore.git;main" >> feeds.conf.default

echo "=================== DIY第一阶段完成 ==================="
