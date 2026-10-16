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
#   5. 双闸门。① 范围闸门：候选必须在 ROOT 之下，出界即整体放弃（防误伤别的仓库）。
#      ② 保护名单：源码 / 文档 / 工具链 / git / 交付目录命中即整体退出。
#      另有 ALLOWED 白名单，从「整体拒绝」里摘出明确允许清理的窄类别
#      （目前只有 worklog-app/app/release/*-replaced.apk）。
#   6. 新增候选组时，必须同步评审 ALLOWED。闸门②是「命中即整体退出」的全有全无
#      语义：只要一个候选落在受保护目录内，整批（含无关组）都会被拒。历史教训 ——
#      build 组清 app/release/*-replaced.apk 曾让整脚本 exit 1，清理功能不可用。
#      已知限制（latent）：ROOT 路径含空格时 add_glob 的 glob 展开会发生词分割 →
#      **候选失真**（既可能漏收，也可能把工作区外的路径收进候选）。安全性**靠闸门 0
#      兜底**（出界候选 → rc=1 整体放弃），**不是**靠「只会漏收」—— 故闸门 0 不可
#      移除、不可重排到闸门①之前。本工作区路径无空格，未触发。
#
#  用法：
#      bash tool/cleanup.sh                    列出全部候选（不改动）
#      bash tool/cleanup.sh --only <组名>      只看某一组
#      bash tool/cleanup.sh --apply --yes      真的送回收站（不问）
#      bash tool/cleanup.sh --apply            真的送回收站（逐组二次确认）
#      bash tool/cleanup.sh -h
#
#  候选组名（--only 的取值）：
#      dill        Dart 中间编译产物 *.dill
#      reviews     复核官工作目录（app 内）
#      sdk         旧 Dart/Flutter SDK 试验残留
#      checktmp    APK 校验临时副本
#      revold      早期复核工作目录（工作区级）
#      appscratch  worklog-app/_scratch 整目录
#      build       构建产物（.dart_tool / build/ / 旧交付包 / 出包历史副本 / 复刻件）
#      scratchall  worklog-app/app/_scratch 整目录（与 dill、reviews 重叠，二选一）
#      junk        诊断 / 日志残留
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

# 从本文件头部注释块提取用法（单一来源，避免两份文案漂移）。
# 范围 = 第 2 行起，到**下一个** `# ===` 分界行（含）。用正则而非固定行号，
# 这样以后在头部增删注释行都不必同步改这里。sed 的 addr2 正则是从
# 起始行的下一行开始匹配，所以第 2 行自身不会提前终止范围。
usage() { sed -n '2,/^# =====/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)     APPLY=1; shift ;;
    --yes|-y)    ASSUME_YES=1; shift ;;
    --only)
      # 缺值守卫（NEW-01）：--only 是最后一个参数时 `shift 2` 会失败，但失败
      #   并不改变 $#，于是 `while [ $# -gt 0 ]` 原地打转 —— 实测直接挂死
      #   （timeout 5 → rc=124，且无任何输出）。必须显式拦下。
      [ $# -ge 2 ] || { echo "[X] --only 缺少组名（例：--only build）" >&2; usage >&2; exit 2; }
      # 显式空串（--only ""）不当成「全部」（NEW-02）：否则与「不传 --only」
      #   语义混淆，用户以为只看了一组、其实跑的是全部。
      [ -n "$2" ] || { echo "[X] --only 的组名不能为空；要看全部请直接不传 --only" >&2; usage >&2; exit 2; }
      ONLY="$2"; shift 2 ;;
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
      # 只收真实存在的路径。
      # 为什么必需：调用点会同时传「glob 实参」和「字面量兜底实参」——字面量不做
      #   路径展开，哪怕目标不存在也会原样返回。不校验就会把不存在的路径计入候选，
      #   使 DRY-RUN 清单虚增，并在执行阶段平白多出一批 absent 噪音。
      #   （独立审查官实测：9 项候选里 8 项其实不存在。）
      [ -e "$f" ] || continue
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
if want build; then
  # 构建产物类：全部可再生 —— .dart_tool 由 build_apk.bat:173 的 flutter pub get 重建，
  # build/ 由 flutter build 重建。
  add_literal "build  Dart 中间产物 .dart_tool（flutter pub get 可重建）" "${ROOT}/worklog-app/app/.dart_tool"
  add_literal "build  Flutter/Gradle 输出 build/（可再生）" "${ROOT}/worklog-app/app/build"
  # 目录内旧包：受保护目录 app/release 之下，靠闸门 1 的 ALLOWED 白名单显式放行
  add_glob "build  被替换的旧版交付 APK" "${ROOT}/worklog-app/app/release/"*-replaced.apk
  add_literal "build  publish_apk 自测夹具 _pubtest" "${ROOT}/_scratch/_build/_pubtest"
  # 出包历史副本：注意 _scratch/_build 同时是本脚本的报告目录（REPORT_DIR），
  #   所以只收该目录下的 *.apk，**不要**把 _scratch/_build 本身列入候选。
  add_glob "build  出包历史副本" "${ROOT}/_scratch/_build/"*.apk
  # 复刻实验件：这些目录没有固定清单，只能按命名约定 _replica* 前缀匹配
  add_glob "build  复刻实验件" "${ROOT}/_scratch/_replica"*
fi
if want scratchall; then
  # 注意：本组与 dill / reviews 组存在**包含关系**（整目录盖住了组内子项）。
  #   用 --only 时请二选一；两项同时入选时，add_glob 的存在性校验会把已被
  #   前一组清掉的子项过滤掉，不会产生幽灵候选。
  add_literal "scratchall  worklog-app/app/_scratch 整目录（含 .dill 与各 worker 目录）" "${ROOT}/worklog-app/app/_scratch"
  # 注：worklog-app/app_backup_before_scaffold 曾列入本组，已移除 —— 它**被 git 跟踪**，
  #   清理会产生工作树删除变更并需额外提交，且仅 121 KB，判定为「保守保留」。
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
# 两类语义不同，不要合并：
#   PROTECTED_PREFIX 目录型 —— 连它的子项一起保护（整棵子树都不能碰）
#   PROTECTED_EXACT  精确型 —— 只保护这个路径本身
PROTECTED_PREFIX=(
  "${ROOT}/.git"
  "${ROOT}/tool"
  "${ROOT}/worklog-app/docs"
  "${ROOT}/worklog-app/app/lib"
  "${ROOT}/worklog-app/app/android"
  "${ROOT}/worklog-app/app/test"
  "${ROOT}/worklog-app/app/tool"
  "${ROOT}/worklog-app/app/release"
)
PROTECTED_EXACT=(
  "${ROOT}/README.md"
  "${ROOT}/.gitignore"
  "${ROOT}/build_apk.bat"
  "${ROOT}/worklog-app/app/pubspec.yaml"
  "${ROOT}/worklog-app/app/pubspec.lock"
)

# 例外白名单：受保护目录内「明确允许清理」的产物。**例外不改保护语义**——
# app/release 子树照旧受保护，只是从「整体拒绝」里摘出下面这一个明确类别。
# 为什么必须有它：闸门 1 是前缀匹配（"$p"|"$p"/*），app/release 在前缀组里；
#   若不放行这条例外，只要目录里存在一个被替换的旧包，整批清理就永远 exit 1
#   —— 连别的组也跑不了（已由独立审查官复刻实证）。
# 设计约束：只放**窄模式**（带后缀限定），绝不要写成 app/release/*。
# 另：只收「普通文件」（NEW-03）—— 若恰好有个**目录**叫 xxx-replaced.apk/，
#   放行它等于放行整棵子树，故用 -f 过滤掉。
ALLOWED=()
for _a in "${ROOT}/worklog-app/app/release/"*-replaced.apk; do
  [ -f "$_a" ] && ALLOWED+=("$_a")
done
unset _a

VIOLATION=0
for t in "${TARGETS[@]}"; do
  # 例外优先：命中白名单 → 只跳过「保护名单」判定；「顶层目录」判定仍然生效
  _allowed=0
  for a in ${ALLOWED[@]+"${ALLOWED[@]}"}; do
    [ "$t" = "$a" ] && { _allowed=1; break; }
  done

  if [ "$_allowed" != "1" ]; then
    for p in "${PROTECTED_PREFIX[@]}"; do
      case "$t" in
        "$p"|"$p"/*) echo "[X] 候选命中保护名单（目录，含子项），拒绝执行：$t"; VIOLATION=1 ;;
      esac
    done
    for p in "${PROTECTED_EXACT[@]}"; do
      case "$t" in
        "$p") echo "[X] 候选命中保护名单（精确），拒绝执行：$t"; VIOLATION=1 ;;
      esac
    done
  fi

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
if TOTAL="$(du -sc "${TARGETS[@]}" 2>/dev/null | tail -1 | cut -f1)" && [ -n "$TOTAL" ]; then
  echo "            体积: $(awk -v k="$TOTAL" 'BEGIN{printf "%.2f GB", k/1048576}')  (${TOTAL} KB)"
else
  # 不让它静默消失（NEW-04）：du 失败（权限/IO）时明说是「未知」，
  #   否则读的人会以为「没有体积行 = 没有候选」。
  echo "            体积: 未知（du 未能计算；不影响清单本身与执行）"
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
