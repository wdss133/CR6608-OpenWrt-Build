#!/usr/bin/env python3
"""CR6608 发布前的静态镜像验收；只读固件，不修改任何镜像。"""
import argparse
import json
import re
import struct
import sys
import tarfile
import zlib
from pathlib import Path

DEVICE = "xiaomi_mi-router-cr6608"
DT_COMPATIBLE = "xiaomi,mi-router-cr6608"
KERNEL_LIMIT = 4 * 1024 * 1024
INITRAMFS_LIMIT = 24 * 1024 * 1024
UBI_MAGIC = b"UBI#"
SQUASHFS_MAGIC = b"hsqs"


def uimage(path, expected_type):
    data = path.read_bytes()
    if len(data) < 64:
        raise ValueError(f"{path.name}: 文件不足 64 字节")
    fields = struct.unpack(">7I4B", data[:32])
    magic, hcrc, _, size, load, entry, dcrc, os_id, arch, kind, comp = fields
    assert magic == 0x27051956, f"{path.name}: 不是 legacy uImage"
    assert arch == 5, f"{path.name}: 不是 MIPS 镜像 (arch={arch})"
    assert kind == expected_type, f"{path.name}: uImage 类型错误 ({kind})"
    assert len(data) == size + 64, f"{path.name}: uImage 长度不一致"
    header = bytearray(data[:64])
    header[4:8] = b"\0" * 4
    assert zlib.crc32(header) & 0xFFFFFFFF == hcrc, f"{path.name}: 头部 CRC 错误"
    assert zlib.crc32(data[64:]) & 0xFFFFFFFF == dcrc, f"{path.name}: 数据 CRC 错误"
    return {
        "bytes": len(data),
        "mib": round(len(data) / 1024 / 1024, 2),
        "type": "kernel" if kind == 2 else "multi",
        "load_address": hex(load),
        "entry_point": hex(entry),
        "name": data[32:64].split(b"\0")[0].decode("ascii", "replace"),
        "header_crc": "OK",
        "data_crc": "OK",
    }


def metadata(blob):
    # fwtool 元数据不是 tar 成员；直接寻找其 JSON 开始和 FW 签名尾。
    match = re.search(rb'\{\s*"metadata_version"\s*:', blob)
    assert match, "sysupgrade: 缺少 fwtool 元数据"
    decoder = json.JSONDecoder()
    info, _ = decoder.raw_decode(blob[match.start():].decode("utf-8", "ignore"))
    return info


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--prefix", default="CR6608")
    args = parser.parse_args()
    root = args.directory
    prefix = args.prefix
    sysupgrade = root / f"{prefix}-immortalwrt-squashfs-sysupgrade.bin"
    initramfs = root / f"{prefix}-immortalwrt-initramfs-kernel.bin"
    firmware = root / f"{prefix}-immortalwrt-squashfs-firmware.bin"
    assert sysupgrade.is_file(), f"缺少 {sysupgrade.name}"
    assert initramfs.is_file(), f"缺少 {initramfs.name}"
    assert firmware.is_file(), f"缺少 {firmware.name}"

    report = {"device": DEVICE, "static_validation": "PASS", "images": {}}
    manifest = root / f"immortalwrt-ramips-mt7621-{DEVICE}.manifest"
    if manifest.is_file():
        packages = set()
        for line in manifest.read_text(encoding="utf-8").splitlines():
            if " - " in line:
                packages.add(line.split(" - ", 1)[0].strip())
        required = {
            "base-files", "procd", "fstools", "mtd", "ubi-utils", "netifd",
            "xray-core", "luci-app-passwall", "luci-app-openclash", "kmod-tun",
        }
        missing = sorted(required - packages)
        assert not missing, f"正式系统 manifest 缺少关键包: {missing}"
        assert "v2ray-core" not in packages, "正式系统不应含 v2ray-core"
        report["full_system_required_packages"] = "PASS"
    rescue_manifest = root / "initramfs.manifest"
    if rescue_manifest.is_file():
        forbidden = ("adguardhome", "xray-core", "zerotier", "ddns-go", "luci-app-passwall")
        content = rescue_manifest.read_text(encoding="utf-8")
        present = [p for p in forbidden if re.search(rf"^{re.escape(p)} - ", content, re.M)]
        assert not present, f"救援盘不应包含完整服务: {present}"
        report["rescue_system_minimal_packages"] = "PASS"
    with tarfile.open(sysupgrade, "r") as archive:
        members = [m for m in archive.getmembers() if m.isfile()]
        names = {Path(m.name).name: m for m in members}
        assert set(names) == {"CONTROL", "kernel", "root"}, f"tar 成员异常: {sorted(names)}"
        control = archive.extractfile(names["CONTROL"]).read().decode()
        assert f"BOARD={DEVICE}" in control, "CONTROL 不是 CR6608"
        kernel_data = archive.extractfile(names["kernel"]).read()
        kernel_path = root / ".verify-kernel.tmp"
        kernel_path.write_bytes(kernel_data)
        try:
            kernel = uimage(kernel_path, 2)
        finally:
            kernel_path.unlink(missing_ok=True)
        assert len(kernel_data) <= KERNEL_LIMIT, "内核超过 CR6608 的 4MiB kernel 分区"
        root_data = archive.extractfile(names["root"]).read()
        # sysupgrade-tar 的 root 是 squashfs，刷机时由 nand.sh 写入 UBI。
        # firmware.bin 才是已经封装好的 UBI，二者不能混淆。
        assert root_data[:4] == SQUASHFS_MAGIC, "root 不是 little-endian squashfs"
        assert root_data.find(b"xray") >= 0 or len(root_data) > 1024 * 1024, "rootfs 异常为空"
        kernel["partition_limit_bytes"] = KERNEL_LIMIT
        report["images"]["sysupgrade"] = {
            "bytes": sysupgrade.stat().st_size,
            "control": control.strip(),
            "kernel": kernel,
            "root_bytes": len(root_data),
            "root_format": "squashfs (写入 NAND 时由 sysupgrade 封装进 UBI)",
        }
    info = metadata(sysupgrade.read_bytes())
    assert info["version"]["board"] == DEVICE, "fwtool board 不匹配"
    assert info["version"]["target"] == "ramips/mt7621", "目标平台不匹配"
    assert DT_COMPATIBLE in info.get("new_supported_devices", []), "设备 compatible 不匹配"
    report["images"]["sysupgrade"]["metadata"] = info

    # firmware.bin = uImage 内核 -> 填充到 4MiB -> UBI。CRC 只覆盖 uImage 的
    # 真实 data size，不能把 4MiB 对齐填充一起算进去（这正是旧校验误报的原因）。
    fw = firmware.read_bytes()
    assert len(fw) >= KERNEL_LIMIT + 4, "firmware.bin 不足 4MiB 内核区 + UBI 头"
    head = fw[:KERNEL_LIMIT]
    fields = struct.unpack(">7I4B", head[:32])
    magic, hcrc, _, size, load, entry, dcrc, os_id, arch, kind, comp = fields
    assert magic == 0x27051956, "firmware.bin: 不是 legacy uImage 内核"
    assert arch == 5, "firmware.bin: 不是 MIPS 内核"
    assert kind == 2, "firmware.bin: uImage 类型不是 kernel"
    assert size + 64 <= KERNEL_LIMIT, "firmware.bin: 内核超过 4MiB 分区"
    header = bytearray(head[:64])
    header[4:8] = b"\0" * 4
    assert zlib.crc32(header) & 0xFFFFFFFF == hcrc, "firmware.bin: 内核头 CRC 错误"
    assert zlib.crc32(head[64:64 + size]) & 0xFFFFFFFF == dcrc, \
        "firmware.bin: 内核数据 CRC 错误（应按 uImage data size 计算，而非 4MiB 填充区）"
    assert fw[KERNEL_LIMIT:KERNEL_LIMIT + 4] == UBI_MAGIC, \
        "firmware.bin: 4MiB 偏移处不是 UBI 头"
    report["images"]["firmware"] = {
        "bytes": len(fw),
        "kernel_bytes": size + 64,
        "kernel_crc": "OK",
        "ubi_offset": KERNEL_LIMIT,
        "layout": "uImage kernel + 4MiB pad + UBI",
    }

    ramdisk = uimage(initramfs, 2)
    assert ramdisk["bytes"] <= INITRAMFS_LIMIT, (
        f"救援 initramfs {ramdisk['mib']}MiB 超过 {INITRAMFS_LIMIT // 1024 // 1024}MiB 上限；"
        "禁止把全插件系统当救援盘发布"
    )
    ramdisk["size_limit_bytes"] = INITRAMFS_LIMIT
    report["images"]["initramfs"] = ramdisk
    report["scope"] = "仅验证镜像结构、设备元数据、CRC 与大小；不能代替实机启动测试"
    (root / "image-validation.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, ValueError, KeyError, tarfile.TarError) as exc:
        print(f"镜像验收失败: {exc}", file=sys.stderr)
        sys.exit(1)
