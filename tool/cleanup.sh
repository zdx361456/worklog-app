#!/usr/bin/env bash
# ===========================================================================
#  cleanup.sh —— 把实施过程中的临时产物送进 Windows 回收站
#
#  安全设计（这个脚本天生危险，所以规则写死在代码里）：
#   1. 默认 DRY-RUN。不加 --apply 就只打印清单，一个字节都不动。
#   2. 永不永久删除。只调 win-recycle-delete 技能（ctypes SHFileOperationW +
#      FOF_ALLOWUNDO），所有东西都能从回收站捞回来。
#   3. 逐项执行。「一次送一批」出现部分失败时无法定位是谁，所以逐项。
#   4. 判成功只看 in_recycle_bin（回收站 $I 记录里按原路径查到）。
#      rc 不可信 —— 实测出现过 rc=120 但操作实际成功。
#   5. 白名单 + 保护名单双闸门。只在 ROOT/_scratch 之下动手；源码、文档、
#      交付目录、git 目录在保护名单里，命中即拒绝执行整体退出。
#
#  用法：
#      bash tool/cleanup.sh                    列出全部候选（不改动）
#      bash tool/cleanup.sh --only dill        只看某一组
#      bash tool/cleanup.sh --apply --yes      真的送回收站（不问）
#      bash tool/cleanup.sh --apply            真的送回收站（逐组二次确认）
#      bash tool/cleanup.sh -h
# ===========================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RECYCLER="${HOME}/.workbuddy/skills/win-recycle-delete/scripts/recycle.py"
REPORT_DIR="${ROOT}/_scratch/_build"
REPORT="${REPORT_DIR}/cleanup_report.txt"

APPLY=0
ASSUME_YES=0
ONLY=""

usage() { sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)     APPLY=1; shift ;;
    --yes|-y)    ASSUME_YES=1; shift ;;
    --only)      ONLY="${2:-}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "[X] 未知参数: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---- 找 python（回收站脚本要用）------------------------------------------
PY=""
if [ -n "${WORKLOG_PY:-}" ] && [ -x "${WORKLOG_PY}" ]; then
  PY="${WORKLOG_PY}"
else
  for c in \
    "C:/Users/${USERNAME}/.workbuddy/binaries/python/versions/3.13.12/python.exe" \
    "${HOME}/.workbuddy/binaries/python/versions/3.13.12/python.exe" \
    "python3" "python"
  do
    if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then PY="$c"; break; fi
  done
fi
[ -n "$PY" ] || { echo "[X] 找不到 python，可用 WORKLOG_PY=<python 路径> 指定"; exit 1; }
[ -f "$RECYCLER" ] || { echo "[X] 找不到回收站脚本：${RECYCLER}"; exit 1; }

shopt -s nullglob

# ---- 候选分组 -------------------------------------------------------------
declare -a TARGETS=()
declare -a GROUP_NAMES=()

add_glob() {  # add_glob <显示名> <glob...>
  local label="$1"; shift
  local found=0
  local p f
  for p in "$@"; do
    for f in $p; do
      TARGETS+=("$f")
      found=$((found+1))
    done
  done
  [ "$found" -gt 0 ] && GROUP_NAMES+=("${label} (${found} 项)")
  return 0
}

add_literal() {  # add_literal <显示名> <path>
  local label="$1" p="$2"
  if [ -e "$p" ]; then
    TARGETS+=("$p")
    GROUP_NAMES+=("${label} (1 项)")
  fi
}

want() {  # want <组名>
  [ -z "$ONLY" ] || [ "$ONLY" = "$1" ] || [ "$ONLY" = "all" ]
}

if want dill; then
  add_glob "dill  Dart 中间编译产物" "${ROOT}/worklog-app/app/_scratch/"*.dill
fi
if want reviews; then
  add_glob "reviews  复核官工作目录（app 内）" "${ROOT}/worklog-app/app/_scratch/"review-*
fi
if want sdk; then
  add_glob "sdk  旧 Dart/Flutter SDK 试验残留" \
    "${ROOT}/_scratch/_dartbeta" "${ROOT}/_scratch/_darttest" \
    "${ROOT}/_scratch/dart-sdk" "${ROOT}/_scratch/dart-sdk.zip" \
    "${ROOT}/_scratch/_flutter3.47.6"
fi
if want checktmp; then
  add_glob "checktmp  APK 校验临时副本" "${ROOT}/_scratch/_checktmp"*
fi
if want revold; then
  add_glob "revold  早期复核工作目录（工作区级）" \
    "${ROOT}/_scratch/rev-"* "${ROOT}/_scratch/_rev"*
fi
if want appscratch; then
  add_glob "appscratch  worklog-app/_scratch 整目录" "${ROOT}/worklog-app/_scratch"
fi
if want junk; then
  add_glob "junk  诊断/日志残留" \
    "${ROOT}/_scratch/_build/_probe"*.bat \
    "${ROOT}/_scratch/_build/_deskpath.tmp" \
    "${ROOT}/_scratch/_build/_stamp.tmp" \
    "${ROOT}/_scratch/_build/_tmps"*.txt \
    "${ROOT}/flutter_0"*.log \
    "${ROOT}/worklog-app/app/flutter_0"*.log
  add_literal "junk  误产生的空壳文件名 []" "${ROOT}/[]"
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "[i] 没有匹配到任何候选（--only ${ONLY:-<全部>}）。"
  exit 0
fi

# ---- 闸门 0：所有候选必须在本工作区之下（防「模糊扫描误伤别的项目」）------
#  为什么要有这条：本机 ~/.workbuddy/ 下还有别的独立仓库（例如 vibe-coding，
#  自带 .git 和它自己的 _scratch）。只要清理逻辑按目录名去扫（"'*_scratch*'"），
#  就会误伤它们。这里改成硬断言：不在 ROOT 之下的候选 → 整体放弃，不执行。
SCOPE_VIOLATION=0
for t in "${TARGETS[@]}"; do
  case "$t" in
    "${ROOT}"/*) : ;;                       # 在工作区内，放行
    *) echo "[X] 候选不在本工作区之下，拒绝执行：$t"; SCOPE_VIOLATION=1 ;;
  esac
done
[ "$SCOPE_VIOLATION" = "1" ] && {
  echo "[X] 出界候选：整体放弃。"
  echo "    本脚本只允许在 ${ROOT} 之下动手；"
  echo "    其它位置（如 ~/.workbuddy/ 下的其它仓库）一律不碰。"
  exit 1
}

# ---- 保护名单：命中即整体拒绝 --------------------------------------------
PROTECTED=(
  "${ROOT}/.git"
  "${ROOT}/tool"
  "${ROOT}/README.md"
  "${ROOT}/.gitignore"
  "${ROOT}/build_apk.bat"
  "${ROOT}/worklog-app/docs"
  "${ROOT}/worklog-app/app/lib"
  "${ROOT}/worklog-app/app/android"
  "${ROOT}/worklog-app/app/test"
  "${ROOT}/worklog-app/app/tool"
  "${ROOT}/worklog-app/app/release"
  "${ROOT}/worklog-app/app/pubspec.yaml"
  "${ROOT}/worklog-app/app/pubspec.lock"
)
VIOLATION=0
for t in "${TARGETS[@]}"; do
  for p in "${PROTECTED[@]}"; do
    case "$t" in
      "$p"|"$p"/*) echo "[X] 候选命中保护名单，拒绝执行：$t"; VIOLATION=1 ;;
    esac
  done
  case "$t" in
    "${ROOT}"|"${ROOT}/_scratch"|"${ROOT}/worklog-app") echo "[X] 候选是顶层目录，拒绝执行：$t"; VIOLATION=1 ;;
  esac
done
[ "$VIOLATION" = "1" ] && { echo "[X] 因保护名单命中，整体放弃。"; exit 1; }

# ---- 展示 ----------------------------------------------------------------
echo "==========================================================="
echo " 清理候选   仓库根: ${ROOT}"
echo "            分组:"
for g in "${GROUP_NAMES[@]}"; do echo "               - ${g}"; done
echo "            合计: ${#TARGETS[@]} 项"
if TOTAL="$(du -sc "${TARGETS[@]}" 2>/dev/null | tail -1 | cut -f1)"; then
  echo "            体积: $(awk -v k="$TOTAL" 'BEGIN{printf "%.2f GB", k/1048576}')  (${TOTAL} KB)"
fi
[ "$APPLY" = "1" ] && echo "            模式: APPLY —— 会真的送入回收站" \
                   || echo "            模式: DRY-RUN —— 只列清单，不动任何东西"
echo "==========================================================="
echo
printf '%s\n' "${TARGETS[@]}" | sed "s|^${ROOT}/|  |"
echo

if [ "$APPLY" != "1" ]; then
  echo "[dry-run] 什么都没动。要真执行请加 --apply （建议先 --apply --yes 的组合自己确认一遍）。"
  exit 0
fi

if [ "$ASSUME_YES" != "1" ]; then
  printf '确认把上面 %d 项送入回收站？输入 yes 继续：' "${#TARGETS[@]}"
  read -r ans
  [ "$ans" = "yes" ] || { echo "[i] 已取消。"; exit 0; }
fi

# ---- 执行（逐项，交给 recycle.py）---------------------------------------
mkdir -p "$REPORT_DIR"
echo "--- 逐项送入回收站 ---"
# recycle.py 内部已逐项执行 + 用回收站 $I 记录核验
"$PY" "$RECYCLER" "${TARGETS[@]}" --report "$REPORT"
rc=$?
echo
echo "--- 回读报告（rc=${rc}；判成功只看 in_recycle_bin）---"
grep -c 'in_recycle_bin : True' "$REPORT" 2>/dev/null | sed 's/^/  成功项数: /'
grep -c 'in_recycle_bin : False' "$REPORT" 2>/dev/null | sed 's/^/  未入回收站: /'
echo "  报告文件: ${REPORT}"
exit "$rc"
