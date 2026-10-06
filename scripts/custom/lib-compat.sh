#!/usr/bin/env bash
#
# lib-compat.sh —— 通用兼容性工具库（可被任何 OpenWrt 定制脚本 source）
#
# 解决的问题：第三方 Go 插件会不断跟进新版 Go（例如 ddns-go 6.13+ 要求 go >= 1.25），
# 而某些源码分支自带的 golang 版本较低，直接编译会以
#   go: ../../go.mod requires go >= 1.25.0 (running go 1.23.12; GOTOOLCHAIN=local)
# 失败，整条流水线就废了。
#
# 这里提供「自动回退」：扫描上游 releases，挑一个与源码树 Go 版本兼容的版本，
# 改写包 Makefile 的 PKG_VERSION / PKG_HASH（hash 由 codeload tarball 现算）；
# 实在找不到就返回失败，由调用方跳过该插件，保证当天固件仍能产出。
#
# 依赖：bash 4+、curl、sha256sum、grep/sed/awk
# 可选环境变量：
#   GH_TOKEN      有则带上，避免 GitHub API 匿名限流
#   GO_SCAN_MAX   最多扫描多少个 release（默认 60）
#   OUT_DIR       回退记录输出目录（默认 /tmp）

log()  { printf '[compat] %s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*"; }

api_curl() {
  local timeout="${1:-30}"
  shift
  if [ -n "${GH_TOKEN:-}" ]; then
    curl -fsSL --retry 2 --max-time "$timeout" -H "Authorization: Bearer ${GH_TOKEN}" "$@" 2>/dev/null
  else
    curl -fsSL --retry 2 --max-time "$timeout" "$@" 2>/dev/null
  fi
}

# 源码树的 golang 版本（feeds/packages/lang/golang/golang/Makefile）
# 注意要 MAJOR_MINOR + PATCH 一起取，否则会得到 1.23 而非真实的 1.23.12，
# 导致「要求 1.23.12」被误判为高于源码树版本。
tree_go_version() {
  local f="${1:-feeds/packages/lang/golang/golang/Makefile}"
  [ -f "$f" ] || return 1
  local maj patch
  maj="$(grep -m1 -E '^GO_VERSION_MAJOR_MINOR:?=' "$f" | sed -E 's/^[^=]*=[[:space:]]*//' | tr -d ' \r')"
  [ -n "$maj" ] || return 1
  patch="$(grep -m1 -E '^GO_VERSION_PATCH:?=' "$f" | sed -E 's/^[^=]*=[[:space:]]*//' | tr -d ' \r')"
  case "$patch" in
    ''|0) printf '%s\n' "$maj" ;;
    *)    printf '%s.%s\n' "$maj" "$patch" ;;
  esac
}

# ver_le a b —— a <= b（按点分段数值比较，缺位补 0）
ver_le() {
  local a="$1" b="$2" i xv yv
  local -a x y
  IFS='.' read -r -a x <<< "$a"
  IFS='.' read -r -a y <<< "$b"
  for i in 0 1 2; do
    xv="${x[$i]:-0}"; yv="${y[$i]:-0}"
    xv="$(printf '%s' "$xv" | tr -cd '0-9')"; yv="$(printf '%s' "$yv" | tr -cd '0-9')"
    xv="${xv:-0}"; yv="${yv:-0}"
    if [ "$xv" -lt "$yv" ]; then return 0; fi
    if [ "$xv" -gt "$yv" ]; then return 1; fi
  done
  return 0
}

# 读某个 tag 的 go.mod 里声明的 go 版本
gomod_go_version() {
  curl -fsSL --retry 2 --max-time 20 "$1" 2>/dev/null \
    | sed -n -E 's/^go[[:space:]]+([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' | head -n1
}

# ensure_go_compatible <包Makefile> <owner/repo> [tag前缀]
#   返回 0 = 可用（原生兼容，或已自动回退并改写 Makefile）
#   返回 1 = 无法兼容（调用方应跳过该插件）
ensure_go_compatible() {
  local mk="$1" gh_repo="$2" prefix="${3:-v}"
  [ -f "$mk" ] || { warn "未找到 $mk，跳过 Go 版本检查"; return 0; }

  local tree cur req
  tree="$(tree_go_version)" || true
  [ -n "${tree:-}" ] || { warn "无法确定源码树 golang 版本，跳过 Go 版本检查"; return 0; }

  cur="$(grep -m1 -E '^PKG_VERSION:?=' "$mk" | sed -E 's/^[^=]*=[[:space:]]*//' | tr -d ' \r')"
  [ -n "$cur" ] || cur=0
  req="$(gomod_go_version "https://raw.githubusercontent.com/${gh_repo}/${prefix}${cur}/go.mod")"
  if [ -z "$req" ]; then
    warn "无法读取 ${gh_repo}@${cur} 的 go.mod（可能不是 Go 包），跳过检查"
    return 0
  fi
  log "${gh_repo} ${cur} 需要 go >= ${req}；源码树 go = ${tree}"
  if ver_le "$req" "$tree"; then
    return 0
  fi

  warn "${gh_repo} ${cur} 需要 go >= ${req}，高于源码树 ${tree}，尝试自动回退到兼容版本"
  # 扫描上游 releases（时间倒序）：
  #   best_margin —— 要求版本 < 源码树版本（有余量，优先，避免依赖漂移卡边界）
  #   best_any    —— 要求版本 <= 源码树版本（兜底）
  local tag ver req2 tries=0 max_tries="${GO_SCAN_MAX:-60}"
  local best_margin="" best_margin_req="" best_any="" best_any_req=""
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    tries=$((tries + 1))
    [ "$tries" -gt "$max_tries" ] && break
    ver="${tag#${prefix}}"
    [ "$ver" = "$cur" ] && continue
    req2="$(gomod_go_version "https://raw.githubusercontent.com/${gh_repo}/${tag}/go.mod")"
    [ -n "$req2" ] || continue
    if ver_le "$req2" "$tree"; then
      [ -n "$best_any" ] || { best_any="$tag"; best_any_req="$req2"; }
      if [ "$req2" != "$tree" ] && [ -z "$best_margin" ]; then
        best_margin="$tag"; best_margin_req="$req2"
        break
      fi
    fi
  done < <(api_curl 30 "https://api.github.com/repos/${gh_repo}/releases?per_page=100" \
             | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/')

  local pick="" pick_req=""
  if [ -n "$best_margin" ]; then pick="$best_margin"; pick_req="$best_margin_req"; else pick="$best_any"; pick_req="$best_any_req"; fi

  if [ -z "$pick" ]; then
    warn "${gh_repo} 未找到在 go ${tree} 下可编译的版本（已扫描 ${tries} 个），本次跳过该插件"
    return 1
  fi

  ver="${pick#${prefix}}"
  log "选定兼容版本 ${ver}（需要 go >= ${pick_req}，本树 go ${tree}），下载并计算哈希…"
  local hash
  hash="$(curl -fsSL --retry 3 --max-time 300 "https://codeload.github.com/${gh_repo}/tar.gz/${pick}" 2>/dev/null | sha256sum | awk '{print $1}')"
  if [ -z "$hash" ]; then
    warn "下载 ${pick} 计算哈希失败，本次跳过该插件"
    return 1
  fi
  sed -i -E "s|^PKG_VERSION:?=.*|PKG_VERSION:=${ver}|" "$mk"
  sed -i -E "s|^PKG_HASH:?=.*|PKG_HASH:=${hash}|" "$mk"
  log "已把 $(basename "$(dirname "$mk")") 回退到 ${ver}"
  printf '%s\t%s\tgo>=%s<=%s\n' "$gh_repo" "$ver" "$pick_req" "$tree" >> "${OUT_DIR:-/tmp}/version-pins.txt"
  return 0
}
