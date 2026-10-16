#!/usr/bin/env bash
# ===========================================================================
#  git-sync.sh —— 一条命令完成「提交 → 推 GitHub → 推 Gitee → 三处 HEAD 比对」
#
#  用法（在仓库任意位置都行，脚本自己找根目录）：
#      bash tool/git-sync.sh -m "fix: 修了 xxx"      提交并推双仓
#      bash tool/git-sync.sh -n -m "..."             演练，不落盘不推送
#      bash tool/git-sync.sh --push-only             只推送，不新建提交
#      bash tool/git-sync.sh --only github -m "..."  只推一个远端
#      bash tool/git-sync.sh -h                      帮助
#
#  Windows 上双击：仓库根的 sync-repos.bat
#
#  设计原则（都是踩出来的）：
#   1. 走 SSH，不需要令牌。令牌只在查私有仓库时才有用。
#   2. 推送后一定回读远端 HEAD 做比对。
#      「git push 退出码 0」不等于「远端停在目标提交」——被 protected 分支挡掉、
#      被 pre-receive hook 静默忽略，都可能返回 0。
#   3. 任一远端比对不上 → 整体退出码非 0，不静默带过。
#   4. 未提交的改动会先打印出来，绝不"悄悄 add -A"。
# ===========================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONF="${SCRIPT_DIR}/repos.conf"

MSG=""
DRY=0
PUSH_ONLY=0
ONLY=""

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() { echo "[X] $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--message) MSG="${2:-}"; shift 2 ;;
    -n|--dry-run) DRY=1; shift ;;
    --push-only)  PUSH_ONLY=1; shift ;;
    --only)       ONLY="${2:-}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "[X] 未知参数: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -f "$CONF" ] || die "找不到配置 ${CONF}"
# shellcheck disable=SC1090
. "$CONF"

cd "$ROOT" || die "进不了 ${ROOT}"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "${ROOT} 不是 git 仓库"

case "$ONLY" in
  "")      REMOTES=("$GITHUB_REMOTE" "$GITEE_REMOTE") ;;
  github)  REMOTES=("$GITHUB_REMOTE") ;;
  gitee)   REMOTES=("$GITEE_REMOTE") ;;
  *)       die "--only 只接受 github 或 gitee" ;;
esac

echo "==========================================================="
echo " git-sync   仓库根: ${ROOT}"
echo "            分支:   ${BRANCH}"
echo "            远端:   ${REMOTES[*]}"
[ "$DRY" = "1" ] && echo "            模式:   DRY-RUN（不落盘、不推送）"
echo "==========================================================="
echo

# --------------------------------------------------------------------------
# 0) 前置检查：远端名字在不在、URL 对不对
# --------------------------------------------------------------------------
FAIL=0
for r in "${REMOTES[@]}"; do
  url="$(git remote get-url "$r" 2>/dev/null)"
  if [ -z "$url" ]; then
    echo "[X] 远端 '${r}' 不存在。补一条："
    echo "    git remote add ${r} $(eval echo \"\${$(echo "$r" | tr 'a-z' 'A-Z')_SSH:-<url>}\")"
    FAIL=1
  else
    echo "[OK] 远端 ${r} -> ${url}"
  fi
done
[ "$FAIL" = "1" ] && die "远端配置不齐，先修好再来"

echo
echo "--- 当前本地 HEAD ---"
git --no-pager log -1 --format='%h  %s  (%ci)'
echo

# --------------------------------------------------------------------------
# 1) 提交
# --------------------------------------------------------------------------
CHANGED="$(git status --porcelain)"
if [ -z "$CHANGED" ]; then
  echo "[i] 工作区干净，没有新提交。"
else
  echo "--- 待提交改动（git status --porcelain）---"
  printf '%s\n' "$CHANGED"
  echo
  if [ "$PUSH_ONLY" = "1" ]; then
    echo "[!] 有未提交改动，但指定了 --push-only，跳过提交。"
  elif [ "$DRY" = "1" ]; then
    echo "[dry-run] 将执行: git add -A && git commit -m \"${MSG:-<自动生成>}\""
  else
    [ -n "$MSG" ] || MSG="chore: 同步 $(date '+%Y-%m-%d %H:%M')"
    git add -A || die "git add -A 失败"
    git commit -m "$MSG" || die "git commit 失败"
    echo "[OK] 已提交: $(git rev-parse --short HEAD)  ${MSG}"
  fi
fi

# --------------------------------------------------------------------------
# 2) 推送
# --------------------------------------------------------------------------
echo
for r in "${REMOTES[@]}"; do
  if [ "$DRY" = "1" ]; then
    echo "[dry-run] git push ${r} ${BRANCH}"
    continue
  fi
  echo "--- push -> ${r} ---"
  if git push "$r" "$BRANCH"; then
    echo "[OK] push ${r} 完成"
  else
    echo "[X] push ${r} 失败（见上面的 git 输出）"
    FAIL=1
  fi
done

[ "$DRY" = "1" ] && { echo; echo "[dry-run] 到此为止。"; exit 0; }

# --------------------------------------------------------------------------
# 3) 比对：本地 HEAD vs 各远端 HEAD（这是唯一可信的成功判据）
# --------------------------------------------------------------------------
echo
LOCAL="$(git rev-parse HEAD)"
printf '%-10s %-42s %s\n' "位置" "SHA" "状态"
printf '%-10s %-42s %s\n' "----------" "------------------------------------------" "--------"
printf '%-10s %-42s %s\n' "local" "$LOCAL" "本地 HEAD"

MISMATCH=0
for r in "${REMOTES[@]}"; do
  remote_sha="$(git ls-remote "$r" "refs/heads/${BRANCH}" 2>/dev/null | awk '{print $1}' | head -1)"
  if [ -z "$remote_sha" ]; then
    printf '%-10s %-42s %s\n' "$r" "(读不到)" "无法确认"
    MISMATCH=1
  elif [ "$remote_sha" = "$LOCAL" ]; then
    printf '%-10s %-42s %s\n' "$r" "$remote_sha" "一致 OK"
  else
    printf '%-10s %-42s %s\n' "$r" "$remote_sha" "不一致 <<<"
    MISMATCH=1
  fi
done

echo
if [ "$MISMATCH" = "0" ] && [ "$FAIL" = "0" ]; then
  echo "[完成] 双仓 HEAD 与本地一致。"
  exit 0
fi
echo "[失败] 有远端未对齐或推送失败，请按上面标出的行处理。"
exit 1
