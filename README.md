# 小米CR6608 OpenWrt/ImmortalWrt 自动编译

## 固件信息
- 源码：ImmortalWrt 24.10
- 机型：小米CR6608（MT7621 + MT7915E AX1800）
- 默认 IP：192.168.1.1
- 默认密码：qq3429510
- 默认主题：Argon

## 预装插件
- ZeroTier（虚拟组网）
- PassWall（科学上网，核心为 **xray-core**，已移除 v2ray-core）
- OpenClash（科学上网）
- iStore 应用商店
- AdGuard Home（广告过滤）
- 动态 DDNS、UPnP、网络唤醒

> DDNSTO 官方源码包一度 404 导致编译失败，已移除，刷机后可在 iStore 里自行安装。

## 关于 xray-core 的说明
`openwrt-24.10` 分支自带的 golang 版本是 **1.23.12**，而 passwall feed 中的
`Xray-core 26.x` 的 `go.mod` 要求 `go >= 1.27`，直接编译必然失败（报错 `Error 255`）。

因此本仓库在 GitHub Actions 的「处理重复包」步骤中删除了 passwall feed 里的重复定义，
实际编译的是 **immortalwrt 官方 packages 源中的 `net/xray-core`（25.2.21，go 1.23）**，
与当前 golang 版本匹配，可正常编译通过。

## 自动编译（GitHub Actions）
工作流文件：`.github/workflows/build.yml`，三种触发方式：

| 触发方式 | 说明 |
| --- | --- |
| push 到 main | 修改 `.config`、`scripts/**`、workflow 文件后自动编译 |
| 手动触发 | Actions 页面 → 编译CR6608固件 → Run workflow |
| 定时编译 | 每月 1 日 18:00 UTC（北京时间每月 2 日 02:00），不需要可删除 workflow 里的 `schedule` 段 |

编译产物：
- 同时上传到 Actions 的 Artifact（保留 7 天）
- 自动发布到 Release（标签 `CR6608-<运行编号>`，仅保留最近 3 个）

若 Actions 未自动运行，请在仓库 **Settings → Actions → General** 里把
「Allow all actions and reusable workflows」选中并保存。

## 固件说明文件
- `CR6608-immortalwrt-squashfs-sysupgrade.bin`（升级用）
- `CR6608-immortalwrt-initramfs-kernel.bin`（救砖用）
- `sha256sums.txt`（校验值）
