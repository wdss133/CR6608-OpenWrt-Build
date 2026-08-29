# 小米CR6608 OpenWrt/ImmortalWrt 自动编译

## 固件信息
- 源码：ImmortalWrt 24.10
- 机型：小米CR6608 (MT7621 + MT7915E AX1800)
- 默认IP：192.168.1.1
- 默认密码：qq3429510
- 默认主题：Argon

## 预装插件
- ZeroTier（虚拟组网）
- DDNSTO（内网穿透）
- PassWall（科学上网）
- OpenClash（科学上网）
- iStore 应用商店
- AdGuard Home（广告过滤）
- 动态DDNS
- UPnP
- 网络唤醒
- SQM QoS

## 编译说明
GitHub Actions 自动编译，编译完成后在 Release 页面下载固件。

固件文件：
- CR6608-immortalwrt-squashfs-sysupgrade.bin（升级用）
- CR6608-immortalwrt-initramfs-kernel.bin（救砖用）
