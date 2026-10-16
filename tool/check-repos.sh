#!/usr/bin/env bash
# ===========================================================================
#  check-repos.sh —— 双仓只读巡检（不改任何东西，不推送、不提交）
#
#  用法：
#      bash tool/check-repos.sh            本地巡检（离线）
#      bash tool/check-repos.sh --online   额外查两个远端的可见性 / 是否可达
#      bash tool/check-repos.sh -h         帮助
#
#  查什么：
#    1. 远端配置是否存在、URL 是否与 repos.conf 一致
#    2. 本地 HEAD 与两个远端 HEAD 是否一致
#    3. 工作区是否干净、有无未推送提交、有无未跟踪文件
#    4. SSH 到两个平台是否通
#    5. （--online）匿名 API 查仓库是否存在、是否公开
#
#  退出码：0 = 全部正常；1 = 有需要处理的地方。
# ===========================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONF="${SCRIPT_DIR}/repos.conf"

ONLINE=0
case "${1:-}" in
  --online) ONLINE=1 ;;
  -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "[X] 未知参数: $1" >&2; exit 2 ;;
esac

[ -f "$CONF" ] || { echo "[X] 找不到配置 ${CONF}" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

BAD=0
ok()   { echo "[OK]   $*"; }
warn() { echo "[!]    $*"; BAD=1; }
bad()  { echo "[X]    $*"; BAD=1; }

cd "$ROOT" || exit 1
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "[X] ${ROOT} 不是 git 仓库"; exit 1; }

echo "==========================================================="
echo " 双仓巡检   ${ROOT}"
echo "==========================================================="
echo

# ---- 1) 远端配置 ---------------------------------------------------------
echo "--- 1. 远端配置 ---"
check_remote() {
  local name="$1" expect="$2" actual
  actual="$(git remote get-url "$name" 2>/dev/null)"
  if [ -z "$actual" ]; then
    bad "远端 ${name} 缺失（期望 ${expect}）"
  elif [ "$actual" = "$expect" ]; then
    ok "远端 ${name} = ${actual}"
  else
    warn "远端 ${name} = ${actual} ，与配置期望的 ${expect} 不一致"
  fi
}
check_remote "$GITHUB_REMOTE" "$GITHUB_SSH"
check_remote "$GITEE_REMOTE"  "$GITEE_SSH"
echo

# ---- 2) HEAD 一致性 ------------------------------------------------------
echo "--- 2. HEAD 一致性（分支 ${BRANCH}）---"
LOCAL="$(git rev-parse HEAD)"
echo "       本地 HEAD   ${LOCAL}   $(git log -1 --format='%s')"
for r in "$GITHUB_REMOTE" "$GITEE_REMOTE"; do
  sha="$(git ls-remote "$r" "refs/heads/${BRANCH}" 2>/dev/null | awk '{print $1}' | head -1)"
  if [ -z "$sha" ]; then
    bad "${r} 读不到 refs/heads/${BRANCH}（网络不通？分支不存在？）"
  elif [ "$sha" = "$LOCAL" ]; then
    ok "${r} 与本地一致"
  else
    warn "${r} = ${sha} ，与本地不一致"
  fi
done
echo

# ---- 3) 工作区状态 -------------------------------------------------------
echo "--- 3. 工作区状态 ---"
DIRTY="$(git status --porcelain)"
if [ -z "$DIRTY" ]; then
  ok "工作区干净"
else
  warn "工作区有未提交内容："
  printf '       %s\n' "$DIRTY"
fi

for r in "$GITHUB_REMOTE" "$GITEE_REMOTE"; do
  ahead="$(git rev-list --count "${r}/${BRANCH}..HEAD" 2>/dev/null || echo '?')"
  behind="$(git rev-list --count "HEAD..${r}/${BRANCH}" 2>/dev/null || echo '?')"
  if [ "$ahead" = "0" ] && [ "$behind" = "0" ]; then
    ok "${r}: 与本地同步（ahead 0 / behind 0）"
  else
    warn "${r}: ahead ${ahead} / behind ${behind}（本地缓存，仅供参考）"
  fi
done
echo

# ---- 4) SSH 连通性 -------------------------------------------------------
echo "--- 4. SSH 连通性（走 22 端口）---"
for h in "$GITHUB_HOST" "$GITEE_HOST"; do
  if timeout 12 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T "git@${h}" >/dev/null 2>&1; then
    ok "${h} SSH 可达"
  else
    # ssh -T 对 git 服务永远返回非 0（因为不给 shell），所以只要不是连接层错误就算通
    msg="$(timeout 12 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T "git@${h}" 2>&1 || true)"
    if printf '%s' "$msg" | grep -qiE 'successfully authenticated|Hi [A-Za-z0-9_-]+!|Welcome to Gitee'; then
      ok "${h} SSH 可达（$(printf '%s' "$msg" | head -1)）"
    else
      bad "${h} SSH 不通：$(printf '%s' "$msg" | head -1)"
    fi
  fi
done
echo

# ---- 5) 在线可见性 -------------------------------------------------------
if [ "$ONLINE" = "1" ]; then
  echo "--- 5. 在线可见性（匿名 API）---"
  check_gh() {
    local json priv
    json="$(curl -s --max-time 20 -H 'Accept: application/vnd.github+json' \
            "https://api.github.com/repos/${GITHUB_SLUG}")"
    priv="$(printf '%s' "$json" | grep -o '"private"[[:space:]]*:[[:space:]]*\(true\|false\)' | head -1 | grep -o 'true\|false')"
    if [ -z "$priv" ]; then
      warn "GitHub 查询无结果（可能是速率限制或仓库不存在）：$(printf '%s' "$json" | head -c 160)"
    elif [ "$priv" = "false" ]; then
      ok "GitHub ${GITHUB_SLUG} 存在且公开"
    else
      warn "GitHub ${GITHUB_SLUG} 存在但为私有"
    fi
  }
  check_gitee() {
    local json priv
    json="$(curl -s --max-time 20 "https://gitee.com/api/v5/repos/${GITEE_SLUG}")"
    priv="$(printf '%s' "$json" | grep -o '"private"[[:space:]]*:[[:space:]]*\(true\|false\)' | head -1 | grep -o 'true\|false')"
    if [ -z "$priv" ]; then
      warn "Gitee 查询无结果：$(printf '%s' "$json" | head -c 160)"
    elif [ "$priv" = "false" ]; then
      ok "Gitee ${GITEE_SLUG} 存在且公开"
    else
      warn "Gitee ${GITEE_SLUG} 存在但为私有"
    fi
  }
  check_gh
  check_gitee
  echo
fi

echo "==========================================================="
if [ "$BAD" = "0" ]; then
  echo " 结论：全部正常。"
  exit 0
fi
echo " 结论：上面有标 [X] / [!] 的项需要处理。"
exit 1
