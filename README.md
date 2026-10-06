# 小米 CR6608 固件自动编译

> 本仓库自动同步上游 ImmortalWrt 源码并编译 **小米 CR6608** 固件。
> 所有定制全部收敛在 **自有文件**（`custom/` + `scripts/custom/`）里，
> 以「新增文件 + 幂等脚本」实现，上游同步不产生冲突；换分支 / 重新 fork 后照旧可用。

## ✅ 本仓库的实际配置

### 1) 编译机型
只编译下列机型（其余全部关闭，缩短编译时间）：

- xiaomi_mi-router-cr6608

### 2) 默认主题
- 默认主题为 **argon**（`luci-theme-argon` + `luci-app-argon-config`），并通过
  `uci-defaults` 兜底确保首次开机即生效；
- 已确保 **aurora 主题**（`luci-theme-aurora` / `luci-app-aurora-config`）不存在。

### 3) 内置插件
（来源：`custom/packages.seed`，增删包只改这一个文件）

- luci-theme-argon
- luci-app-argon-config
- kmod-tun
- easytier-noweb
- luci-app-easytier
- zerotier
- luci-app-zerotier
- ddns-go
- luci-app-ddns-go
- luci-app-store
- luci-lib-taskd
- luci-lib-xterm
- taskd
- luci-compat
- luci-lua-runtime
- luci-app-wechatpush

其中第三方插件在编译时**从各自上游仓库拉取最新版**，并在发布说明中记录
**版本号与上游更新日期**（见下方「发布策略」）。

### 4) 发布策略（全自动）
每次编译后：

- 创建一个**时间戳 tag** 的 Release：`CR6608-YYYYMMDD-HHMM`（北京时间）；
- 更新滚动 Release `CR6608-latest` —— **下载链接固定**，永远指向最新固件；
- 自动清理，保留规则（取并集）：
  `latest` + 最近 **36** 个时间戳版本 + **每月最后一次编译**（月度归档）+ 当天全部编译。
- 只清理时间戳格式的 `CR6608-YYYYMMDD-HHMM`；其它 tag（含历史运行编号版本如 `CR6608-2`）一律不动，避免误删已有可用固件。

### 5) 自动化
- 每天**北京时间 21:00**（UTC 13:00）自动同步上游源码并编译（`.github/workflows/build.yml`）；
- 也可在 Actions 页手动 `Run workflow`（可选是否发布 Release）；
- 每次编译后自动重新生成这份 README 并提交回仓库。
- 想换上游源码：改 `.github/workflows/build.yml` 里的 `SOURCE_REPO` / `SOURCE_BRANCH` 即可，脚本会自动探测可用分支。

上游源码：https://github.com/immortalwrt/immortalwrt.git（分支 openwrt-24.10）。

### 6) 上游变化时的自我保护（保证每天都能产出固件）
上游仓库随时会变，这套脚本对常见变化都做了兜底：

| 上游可能的变化 | 脚本的应对 |
|---|---|
| 默认分支改名 / 换分支 | 候选分支自动探测（`SOURCE_FALLBACK_BRANCHES`），探测不到才报错 |
| 第三方仓库把 master 改 main | `git ls-remote` 探测实际存在的分支 + 克隆失败重试 3 次 |
| 插件不支持本机架构 | 读插件 Makefile 的架构白名单与 `APP_ARCH` 映射，不支持就跳过并告警 |
| Go 插件跟进新版 Go（如 ddns-go 6.13+ 要求 go ≥ 1.25） | **自动回退**到与源码树 golang 兼容的版本，现算 `PKG_HASH` 写回；找不到才跳过 |
| 包名写错 / PROVIDES 虚拟名 | defconfig 前后比对，被静默丢弃的包会在日志里列出（warning） |
| 关键包缺失 | xray-core / geoip / geosite / adguardhome / passwall / openclash / argon / kmod-tun 硬校验，缺失即失败 |
| 主题被上游换掉 | 幂等切换回 argon，并用 `uci-defaults` 兜底 |

> 只要 `custom/` 与 `scripts/custom/` 这几个文件还在，换分支 / 重新 fork 后都能照旧自动跑；
> 想加插件只改 `custom/packages.seed`。

## 🚀 刷机

从 `CR6608-latest` 下载：

- `CR6608-immortalwrt-squashfs-sysupgrade.bin` —— 已刷过 OpenWrt 时升级用
  （LuCI「系统 → 备份/刷写固件」，首刷建议不保留配置）；
- `CR6608-immortalwrt-initramfs-kernel.bin` —— 救砖 / 首次刷入中转用；
- `sha256sums.txt` —— 校验值（`sha256sum -c sha256sums.txt`）。

默认地址 **192.168.1.1**，默认密码 **qq3429510**。

## 🔁 换分支 / 重新 fork 后继续使用

定制全部在自有文件里，迁移时带上这些文件即可：

| 文件 | 作用 |
|---|---|
| `.github/workflows/build.yml` | 同步上游 + 编译 + 发布流水线 |
| `scripts/custom/customize.sh` | 应用全部定制（插件清单 / 主题 / 机型筛选 / 第三方插件拉取与版本表） |
| `scripts/custom/release.sh` | 时间戳 tag 发布 + `latest` + 保留策略清理 |
| `scripts/custom/gen-readme.sh` | 生成本 README |
| `custom/packages.seed` | 新增 / 启用插件清单（改包只改这里） |
| `custom/devices.include`、`devices.exclude` | 机型白名单 / 黑名单 |
| `.config` | 基础配置（目标平台、基础包、PassWall 等） |
| `scripts/diy-part1.sh`、`scripts/diy-part2.sh` | 第三方 feeds / 默认 IP、密码、主机名、WLAN、SSL 后端修复 |

---
_本 README 由 `scripts/custom/gen-readme.sh` 自动生成；要改内容请改脚本或 `custom/` 配置，勿手工大改。_
