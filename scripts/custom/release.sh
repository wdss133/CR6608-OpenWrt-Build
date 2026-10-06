#!/usr/bin/env bash
#
# release.sh —— 小米 CR6608 固件「发布」脚本（与 workflow 解耦，便于 fork / 换分支复用）
#
# 职责：
#   1) 依据固件清单与构建阶段产物生成发布说明（含第三方插件拉取到的版本号与上游更新日期）；
#   2) 每次编译创建一个「时间戳 tag」Release：<PREFIX>-YYYYMMDD-HHMM（北京时间）；
#   3) 同时维护滚动 Release <PREFIX>-latest，下载链接固定，永远指向最新固件；
#   4) 清理旧 Release。命名规则只有一种：<PREFIX>-YYYYMMDD-HHMM（北京时间）。
#      任何不符合该格式的 <PREFIX>-* Release（旧的运行编号式命名）一律删除。
#      保留规则（取并集，全部保住）：
#        - 滚动 <PREFIX>-latest（每次编译覆盖，下载链接固定）
#        - 最近 KEEP_RECENT 个时间戳 Release（默认 36，约等于最近 36 天的每日编译）
#        - 每个月的最后一次编译（月度归档），保留最近 KEEP_MONTHS 个月（默认 36 个月 = 3 年）
#        - 当天的全部编译
#      只删除以 <PREFIX>- 开头的 Release，绝不动其它 tag。
#
# 用法：
#   release.sh <artifact_dir> [tag_prefix] [keep_recent] [keep_months]
# 环境变量：
#   GH_TOKEN            必填（contents:write），gh CLI 使用
#   GITHUB_REPOSITORY   必填（owner/repo）；本地调试可用 REPO 覆盖
#   TAG_TZ              可选，tag 使用哪个时区的时间戳，默认 Asia/Shanghai
#   KEEP_RECENT         可选，保留最近几次编译，默认 36
#   KEEP_MONTHS         可选，月度归档保留几个月，默认 36（=3 年）
#   PRUNE_LEGACY        可选，是否清理非时间戳命名的旧 Release，默认 1（清理）
#   VERSION_KERNEL      可选，写入发布说明
#   SOURCE_REPO/SOURCE_BRANCH 可选，写入发布说明
#
set -Eeuo pipefail

ART_DIR="${1:?用法: release.sh <artifact_dir> [tag_prefix] [keep_recent] [keep_months]}"
PREFIX="${2:-CR6608}"
KEEP_RECENT="${3:-${KEEP_RECENT:-36}}"
KEEP_MONTHS="${4:-${KEEP_MONTHS:-36}}"
PRUNE_LEGACY="${PRUNE_LEGACY:-1}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
TAG_TZ="${TAG_TZ:-Asia/Shanghai}"
VERSION_KERNEL="${VERSION_KERNEL:-unknown}"
SOURCE_REPO="${SOURCE_REPO:-https://github.com/immortalwrt/immortalwrt.git}"
SOURCE_BRANCH="${SOURCE_BRANCH:-openwrt-24.10}"
DEVICE_NAME="${DEVICE_NAME:-${DEVICE:-xiaomi_mi-router-cr6608}}"

log() { printf '[release] %s\n' "$*"; }
die() { printf '[release][error] %s\n' "$*" >&2; exit 1; }

[ -d "$ART_DIR" ] || die "artifact 目录不存在: $ART_DIR"
[ -n "$REPO" ] || die "需要 GITHUB_REPOSITORY（或 REPO）"
command -v gh >/dev/null 2>&1 || die "未找到 gh CLI"

STAMP="$(TZ="$TAG_TZ" date '+%Y%m%d-%H%M')"
TODAY="$(TZ="$TAG_TZ" date '+%Y%m%d')"
NOW="$(TZ="$TAG_TZ" date '+%Y-%m-%d %H:%M')（北京时间）"
TS_TAG="${PREFIX}-${STAMP}"
LATEST_TAG="${PREFIX}-latest"
# 月度归档的时间下界：保留最近 KEEP_MONTHS 个月（含当月）
CUTOFF_MONTH="$(TZ="$TAG_TZ" date -d "-$((KEEP_MONTHS - 1)) months" '+%Y%m')"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

############################ 1) 组装发布说明 ############################

PLUGINS_MD="$(ls "$ART_DIR"/*.plugins.md 2>/dev/null | head -n1 || true)"
SRC_TXT="$(ls "$ART_DIR"/third-party-sources.txt 2>/dev/null | head -n1 || true)"
COMMIT_TXT="$(ls "$ART_DIR"/source-commit.txt 2>/dev/null | head -n1 || true)"
PIN_TXT="$(ls "$ART_DIR"/version-pins.txt 2>/dev/null | head -n1 || true)"
MAN="$(ls "$ART_DIR"/*.manifest 2>/dev/null | head -n1 || true)"

SOURCE_COMMIT="（未知）"
[ -n "$COMMIT_TXT" ] && SOURCE_COMMIT="$(head -n1 "$COMMIT_TXT" | tr -d '\r')"

ADDED_LIST="$(sed -n 's/^| \([^|]*\) |.*/\1/p' "$PLUGINS_MD" 2>/dev/null | paste -sd '、' - || true)"

BODY="$WORK/body.md"
{
  echo "## 小米 CR6608 固件（自动编译）"
  echo ""
  echo "> 🔗 **滚动 latest**：[\`${LATEST_TAG}\`](https://github.com/${REPO}/releases/tag/${LATEST_TAG}) 下载链接固定，永远指向最新固件。"
  echo "> 本页为时间戳版本 **\`${TS_TAG}\`**（北京时间 ${NOW}）。"
  echo ""
  echo "### 📒 固件信息"
  echo "- 源码：\`${SOURCE_REPO}\`（分支 \`${SOURCE_BRANCH}\`）"
  echo "- 源码提交：\`${SOURCE_COMMIT}\`"
  echo "- 目标机型：\`${DEVICE_NAME}\`（MT7621，ramips/mt7621）"
  echo "- 默认主题：**argon**（已确保无 aurora 主题）"
  echo "- 默认地址：**192.168.1.1**"
  echo "- 默认密码：**qq3429510**"
  echo "- 内核版本：**${VERSION_KERNEL}**"
  echo "- 编译时间：${NOW}"
  echo ""
  echo "### 🧩 内置插件（编译时从上游拉取的版本）"
  echo ""
  if [ -n "$PLUGINS_MD" ]; then
    cat "$PLUGINS_MD"
  else
    echo "（未采集到插件信息）"
  fi
  echo ""
  echo "### 📌 第三方源快照"
  echo ""
  if [ -n "$SRC_TXT" ]; then
    echo '| 仓库 | 分支 | 提交 | 上游最后提交日期 |'
    echo '|---|---|---|---|'
    tail -n +2 "$SRC_TXT" | awk -F'\t' 'NF>=3{printf "| %s | %s | `%s` | %s |\n", $1, $2, substr($3,1,10), ($4==""?"-":$4)}'
  else
    echo "（无第三方源记录）"
  fi
  echo ""
  if [ -n "$PIN_TXT" ]; then
    echo "### 🔧 版本自动回退记录"
    echo ""
    echo "以下第三方插件因上游要求更高版本的 Go（源码树 golang 版本有限），"
    echo "已自动回退到与当前源码树兼容的最新版本："
    echo ""
    echo '| 仓库 | 采用的版本 | 版本约束 |'
    echo '|---|---|---|'
    awk -F'\t' 'NF>=3{printf "| %s | %s | %s |\n", $1, $2, $3}' "$PIN_TXT"
    echo ""
  fi
  echo "### 🗂 Release 保留策略"
  echo "- 命名规则只有一种：\`${PREFIX}-YYYYMMDD-HHMM\`（北京时间），不再使用运行编号式命名"
  echo "- 每次编译生成一个时间戳 tag，同时更新滚动 \`${LATEST_TAG}\`（链接固定，永远指向最新固件）"
  echo "- 自动清理保留（取并集）："
  echo "  1. 滚动 \`${LATEST_TAG}\`"
  echo "  2. 最近 **${KEEP_RECENT}** 次编译"
  echo "  3. 每月最后一次编译，保留最近 **${KEEP_MONTHS}** 个月（≈3 年，月度归档）"
  echo "  4. 当天的全部编译"
  echo "- 不符合时间戳格式的历史 Release 会被自动清理"
} > "$BODY"
log "发布说明已生成: $BODY"

############################ 2) 发布 / 更新 Release ############################

publish() {
  local tag="$1" title="$2"
  if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
    gh release edit "$tag" --repo "$REPO" --title "$title" --notes-file "$BODY"
    gh release upload "$tag" "$ART_DIR"/* --repo "$REPO" --clobber
    log "已更新 Release: $tag"
  else
    gh release create "$tag" "$ART_DIR"/* --repo "$REPO" --title "$title" --notes-file "$BODY"
    log "已创建 Release: $tag"
  fi
}

publish "$TS_TAG" "${PREFIX} ${STAMP}"
publish "$LATEST_TAG" "${PREFIX} latest（最新固件）"

############################ 3) 清理旧 Release ############################

mapfile -t TS_TAGS < <(
  gh release list --repo "$REPO" --limit 500 --json tagName --jq '.[].tagName' \
  | grep -E "^${PREFIX}-[0-9]{8}-[0-9]{4}$" | sort -r || true
)

declare -A KEEP=()
KEEP["$LATEST_TAG"]=1

# 最近 KEEP_RECENT 个时间戳版本
i=0
for t in "${TS_TAGS[@]:-}"; do
  [ -n "$t" ] || continue
  [ "$i" -lt "$KEEP_RECENT" ] && KEEP["$t"]=1
  i=$((i + 1))
done

# 每个月的最后一次编译（TS_TAGS 已按时间倒序，每个 YYYYMM 的首次出现即该月最后一次）
# 只保留时间下界 CUTOFF_MONTH 之后的月份，即最近 KEEP_MONTHS 个月（默认 36 个月 = 3 年）
declare -A MONTH_SEEN=()
for t in "${TS_TAGS[@]:-}"; do
  [ -n "$t" ] || continue
  d="${t#${PREFIX}-}"; m="${d:0:6}"
  [[ "$m" < "$CUTOFF_MONTH" ]] && continue
  if [ -z "${MONTH_SEEN[$m]:-}" ]; then
    KEEP["$t"]=1
    MONTH_SEEN[$m]=1
  fi
done

# 当天的全部
for t in "${TS_TAGS[@]:-}"; do
  [ -n "$t" ] || continue
  d="${t#${PREFIX}-}"
  case "$d" in "${TODAY}-"*) KEEP["$t"]=1 ;; esac
done

log "时间戳版本共 ${#TS_TAGS[@]} 个，月度归档 ${#MONTH_SEEN[@]} 个月（下界 ${CUTOFF_MONTH}），保留 ${#KEEP[@]} 个 Release"

# 清理超出保留集合的「时间戳格式」Release：<PREFIX>-YYYYMMDD-HHMM
for t in "${TS_TAGS[@]:-}"; do
  [ -n "$t" ] || continue
  [ -n "${KEEP[$t]:-}" ] && continue
  log "删除旧 Release: $t"
  gh release delete "$t" --repo "$REPO" --yes --cleanup-tag || true
done

# 清理「非时间戳格式」的历史 Release（如旧的运行编号命名 CR6608-2 / CR6608-4 / CR6608-142）
# 命名规则已统一为 <PREFIX>-YYYYMMDD-HHMM，旧命名一律不再保留
if [ "$PRUNE_LEGACY" = "1" ]; then
  mapfile -t LEGACY < <(
    gh release list --repo "$REPO" --limit 500 --json tagName --jq '.[].tagName' \
    | grep -E "^${PREFIX}(-|$)" | grep -vE "^${PREFIX}-[0-9]{8}-[0-9]{4}$" | grep -vx "$LATEST_TAG" || true
  )
  for t in "${LEGACY[@]:-}"; do
    [ -n "$t" ] || continue
    log "删除非时间戳命名的旧 Release: $t"
    gh release delete "$t" --repo "$REPO" --yes --cleanup-tag || true
  done
  [ "${#LEGACY[@]}" -gt 0 ] && log "已清理 ${#LEGACY[@]} 个非时间戳命名的旧 Release"
else
  log "PRUNE_LEGACY=0，跳过非时间戳命名旧 Release 的清理"
fi

log "完成：本次时间戳 tag = ${TS_TAG}"
