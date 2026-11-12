# CR6608 刷机说明（先确认你使用哪个刷机入口）

## 重要：三个文件不是三种“任选其一”的刷机包

- `CR6608-immortalwrt-initramfs-kernel.bin`：**轻量救援/首次过渡系统**。只用于 PB-Boot 启动后进入 LuCI，再刷完整 sysupgrade。它不是全功能正式系统，无线默认关闭，root 无密码，仅限电脑有线直连使用。
- `CR6608-immortalwrt-squashfs-sysupgrade.bin`：**完整正式系统**。用于已经运行 OpenWrt/ImmortalWrt 的设备升级，或由 initramfs 过渡系统写入 NAND。
- `CR6608-immortalwrt-squashfs-firmware.bin`：**上游 NAND 布局的完整 firmware 镜像**，供原厂 SSH/mtd 流程或明确支持该格式的恢复环境使用。**不要在 PB-Boot 网页里把它当 initramfs 上传。**

## A. PB-Boot 首次刷入或恢复（常用路线）

1. 先下载并核对 `sha256sums.txt`；不要混用不同时间戳 Release 的 initramfs 和 sysupgrade。
2. 电脑用网线连接 LAN，断开其他网络；电脑设为 `192.168.1.10/24`。
3. 断电，按住 Reset 后通电，进入 PB-Boot（通常为 `192.168.1.1`）。
4. 在 PB-Boot 上传 **initramfs-kernel.bin**。等待启动完成，不要断电。
5. 浏览器进入 `http://192.168.1.1`。救援系统 root 无密码，无线默认关闭，请使用有线。
6. 在 LuCI「系统 → 备份/刷写固件」上传 **squashfs-sysupgrade.bin**，**取消保留配置**，刷入后等待重启。
7. 完整系统默认地址 `192.168.1.1`，root 密码 `password`，无线默认关闭。首次进入后请修改密码，再按需启用无线。

如果第 4 步 initramfs 本身就无法进入，请不要再刷 sysupgrade；保留 PB-Boot，换官方已验证版本恢复。静态校验无法替代实机启动测试。

## B. 已经运行 OpenWrt / ImmortalWrt

只使用 **squashfs-sysupgrade.bin**。跨版本或从本项目旧版升级时建议不保留配置；CR6608 从 swconfig 迁移到 DSA 时必须重置配置。

SSH 命令示例（先把文件上传到 `/tmp`，并核对型号和校验值）：

```sh
sysupgrade -n /tmp/CR6608-immortalwrt-squashfs-sysupgrade.bin
```

**不要在 initramfs 或 PB-Boot 网页里直接执行/上传 firmware.bin 代替上述步骤。**

## C. 原厂 SSH / mtd 路线（仅熟悉 NAND 布局时使用）

上游 CR6608 原厂迁移文档使用 `squashfs-firmware.bin` 写入原厂 `firmware` 分区。该流程与 PB-Boot 流程不同，必须先备份原厂分区、确认 Bootloader 和分区布局。本项目不提供或刷写 Bootloader，也不会修改 DTS 分区表。

## 无法启动时能提供的最小信息

不需要先进入 OpenWrt 才能记录：请记下**刷机入口（PB-Boot/Breed/原厂/LuCI）、上传的文件名、是否保留配置、刷前系统、指示灯状态、是否能再次进入 PB-Boot**。有 TTL 时记录 115200 8N1 串口日志；不要接 VCC，仅 TX/RX/GND，电平 3.3V。
