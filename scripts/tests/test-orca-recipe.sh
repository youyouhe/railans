#!/usr/bin/env bash
# scripts/tests/test-orca-recipe.sh — orca 形态⑤ recipe 垫片测试组
#
# 被测对象：examples/orca/{orca.yaml,scripts/*.sh}（公开示范 recipe）。
# 唯一事实源：形态⑤施工图（内部方案文档，不入公开树）§2 对接面 / §3 生命周期
# 映射 / §5 并发与配额 / §6 测试清单；本文件只落垫片可判的用例子集：
#   case_00   静态：bash -n、执行位、orca.yaml 条目形态（id pattern / 四命令）
#   case_tc01 create 转换：boxView→connection JSON 逐字段 + 结果契约（单 JSON
#             对象、schemaVersion 1、绝对 projectRoot、target 字段集 strict）
#   case_tc02 create 错误透传：信封 code 上 stderr、exit 1；retryable 按
#             retry_after_seconds 退避重试（垫片计数）；非 retryable 不重试
#   case_tc03 create 幂等复用：stopped 态 boxView 仍产出可连接 target（无 wait）
#   case_tc04 repo 本地锁：无锁→过并记锁；异 workspace 持锁→拒；同 workspace
#             重放→过；destroy 释放锁
#   case_tc05 suspend：stdin payload 提取 userData.box → 垫片收到 stop <box>；
#             payload 缺键→拒
#   case_tc06 resume：start 成功→重发新鲜 JSON（expires 刷新、target 保持、
#             identityFile 以当前钥匙为准）；start not-found→回退 create 重建；
#             start 其他失败→失败透传
#   case_tc07 userData 回传闭环：create 输出 → payload 原样回传 → suspend/
#             destroy 据此定位箱名（垫片 argv 断言）
#   case_tc08 destroy：rm + ls 复核通过；deleting 尾巴→复核重试收敛；复核
#             超限→exit 非 0；rm not-found 容忍为成功
#   case_tc09 检出模式守卫：ORCA_RECIPE_RESULT_SCHEMA_VERSION=2 显式拒绝
#   case_tc10 环境面：必填 env 缺失快速失败；钥匙路径归一化（相对/~/→绝对）；
#             ctl 地址/端口/钥匙路径透传断言（垫片 argv）
#
# 隔离承诺（硬红线）：ssh 全垫片——脚本统一经 RAILANS_CTL_SSH 调控制面，测试
# 指向罐头回放垫片（new/stop/start/rm/ls 按 $FAKE_SCEN 场景文件回放，argv 全量
# 落日志供断言）；sleep 垫片瞬时返回加速重试/复核路径；全部写入 mktemp -d 临时
# 目录。零网络、零真机、零真集群。

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$HERE/../../examples/orca/scripts"
YAML="$HERE/../../examples/orca/orca.yaml"

PASS=0
FAIL=0
TMP=""
REAL_HOME="$HOME"

t_ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
t_fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

assert_eq() {  # <说明> <期望> <实际>
  if [[ "$2" == "$3" ]]; then t_ok "$1"; else t_fail "$1（期望 [$2] 实际 [$3]）"; fi
}
assert_cont() {  # <说明> <子串> <整体>
  if [[ "$3" == *"$2"* ]]; then t_ok "$1"; else t_fail "$1（未找到 [$2]）"; fi
}
assert_no() {  # <说明> <子串> <整体>
  if [[ "$3" != *"$2"* ]]; then t_ok "$1"; else t_fail "$1（不应出现 [$2]）"; fi
}
assert_rc() {  # <说明> <期望rc> <实际rc>
  if [[ "$2" == "$3" ]]; then t_ok "$1"; else t_fail "$1（期望 rc=$2 实际 rc=$3）"; fi
}
assert_file() {  # <说明> <路径> <存在|不存在|非空|空>
  case "$3" in
    存在)   [[ -e "$2" ]] && t_ok "$1" || t_fail "$1（$2 应存在）";;
    不存在) [[ ! -e "$2" ]] && t_ok "$1" || t_fail "$1（$2 应不存在）";;
    非空)   [[ -s "$2" ]] && t_ok "$1" || t_fail "$1（$2 应非空）";;
    空)     [[ ! -s "$2" ]] && t_ok "$1" || t_fail "$1（$2 应为空）";;
  esac
}

cleanup() {
  if [[ -n "${TMP:-}" ]]; then
    chmod -R u+rwX "$TMP" 2>/dev/null
    rm -rf "$TMP"
  fi
  export HOME="$REAL_HOME"
}
trap cleanup EXIT

# jget <json文件> <py表达式（d 为已解析对象）>
jget() {
  python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

SCEN=""   # 当前沙盒的场景文件目录（垫片按它回放）

# ---- 每用例独立沙盒 ----
case_setup() {
  cleanup
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/bin" "$TMP/scen" "$TMP/repo"
  SCEN="$TMP/scen"

  # 假控制面垫片：剥离脚本拼的 ssh 连接参数后按子命令回放罐头；argv 全量落日志。
  cat >"$TMP/bin/fake-railans-ctl" <<'SHIM'
#!/usr/bin/env bash
# 测试垫片：模拟 railans 控制面 SSH 入口（罐头回放，零网络）
set -u
SCEN="${FAKE_SCEN:?FAKE_SCEN 未设置}"
LOG="${FAKE_CTL_LOG:?FAKE_CTL_LOG 未设置}"
printf '%s\n' "$*" >>"$LOG"
args=("$@")
i=0
while (( i < ${#args[@]} )); do
  case "${args[$i]}" in
    -n)          i=$((i + 1)) ;;
    -p|-i|-o)    i=$((i + 2)) ;;
    git@*)       i=$((i + 1)); break ;;
    *)           break ;;
  esac
done
rest=("${args[@]:$i}")
cmd="${rest[0]:-}"
box="${rest[1]:-}"
bump() {  # 垫片内部调用计数（.new_calls / .ls_calls）
  local f="$SCEN/$1" n
  n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "$n" >"$f"
}
case "$cmd" in
  new)
    bump .new_calls
    failn=$(cat "$SCEN/new-fail-times" 2>/dev/null || echo 0)
    if (( $(cat "$SCEN/.new_calls") <= failn )); then
      cat "$SCEN/new-error.json"; exit 1
    fi
    cat "$SCEN/new.json"; exit 0 ;;
  stop|start|rm)
    bump ".$cmd.calls"
    rc=0
    [[ -f "$SCEN/$cmd.rc" ]] && rc=$(cat "$SCEN/$cmd.rc")
    if [[ -f "$SCEN/$cmd.out" ]]; then
      cat "$SCEN/$cmd.out"
    else
      case "$cmd" in
        stop)  printf '%s stopped (disk kept)\n' "$box" ;;
        start) printf '%s started\n' "$box" ;;
        rm)    printf 'removed %s\n' "$box" ;;
      esac
    fi
    exit "$rc" ;;
  ls)
    bump .ls_calls
    gone_after=$(cat "$SCEN/ls-gone-after" 2>/dev/null || echo 0)
    if (( gone_after > 0 && $(cat "$SCEN/.ls_calls") > gone_after )); then
      cat "$SCEN/ls-gone.json"
    elif [[ -f "$SCEN/ls.json" ]]; then
      cat "$SCEN/ls.json"
    else
      printf '[]\n'
    fi
    exit 0 ;;
  *)
    printf 'fake-railans-ctl: 未知子命令 %s\n' "$cmd" >&2
    exit 64 ;;
esac
SHIM

  # sleep 垫片：瞬时返回（记录实参供断言退避间隔用）
  cat >"$TMP/bin/sleep" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_SLEEP_LOG:-/dev/null}"
exit 0
SHIM
  chmod +x "$TMP/bin/fake-railans-ctl" "$TMP/bin/sleep"
  : >"$TMP/bin/.keep"

  # 罐头 boxView（running）与空 ls —— 多数用例的默认场景
  cat >"$SCEN/new.json" <<'JSON'
{"box": "box-ab12cd", "state": "running", "node": "node-1", "vm_ip": "192.168.1.42", "ssh": "ssh -p 22001 dev@ctl.example.org", "ssh_port": 22001, "ssh_host": "ctl.example.org", "preview": "https://box-ab12cd.example.org", "expires": "2026-12-02T00:00:00Z", "shared": false}
JSON
  printf '[]\n' >"$SCEN/ls-gone.json"

  # 生命周期 stdin payload（create 结果的模拟回传形态）
  cat >"$TMP/payload.json" <<JSON
{"schemaVersion":1,"mode":"suspend","recipeId":"railans-box","instanceId":"orca-0001","projectId":"proj-1","workspaceId":"ws-1","workspaceName":"demo workspace","recipeResult":{"schemaVersion":1,"connection":{"type":"ssh","target":{"label":"railans box-ab12cd","host":"ctl.example.org","port":22001,"username":"dev","identityFile":"/tmp/stale-provider-key"},"projectRoot":"/home/dev/orca/demo-workspace"},"userData":{"provider":"railans","box":"box-ab12cd","expires":"2026-11-01T00:00:00Z"}}}
JSON

  # provider 钥匙：只造一个空文件占路径（垫片不校钥，真钥材料零参与）
  : >"$TMP/provider_key"
  chmod 600 "$TMP/provider_key"

  export HOME="$TMP"
  export PATH="$TMP/bin:$PATH"
  export RAILANS_CTL_SSH="$TMP/bin/fake-railans-ctl"
  export FAKE_SCEN="$SCEN"
  export FAKE_CTL_LOG="$TMP/ctl.log"
  export FAKE_SLEEP_LOG="$TMP/sleep.log"
  : >"$FAKE_CTL_LOG"
  : >"$FAKE_SLEEP_LOG"
  export RAILANS_CTL_HOST=ctl.example.org
  export RAILANS_CTL_PORT=2222
  export RAILANS_PROVIDER_KEY="$TMP/provider_key"
  unset RAILANS_STATE_FILE RAILANS_PROJECT_ROOT_BASE
  unset ORCA_RECIPE_RESULT_SCHEMA_VERSION
  export ORCA_REPO_PATH="$TMP/repo"
  export ORCA_RECIPE_ID=railans-box
  export ORCA_PROJECT_ID=proj-1
  export ORCA_WORKSPACE_ID=ws-1
  export ORCA_WORKSPACE_NAME='demo workspace'
}

# run_script <脚本路径> [stdin重定向由调用方附加]；stdout/stderr 落 $TMP/out|err，rc 落 $RC
run_script() {
  RC=0
  "$1" >"$TMP/out" 2>"$TMP/err" || RC=$?
}

# run_script_in <cwd> <脚本路径>：orca runner 以 repo 根为 cwd 起 recipe 命令，
# 相对钥匙路径等对 cwd 敏感的用例走这条。
run_script_in() {
  RC=0
  local d="$1" s="$2"
  (cd "$d" && "$s" >"$TMP/out" 2>"$TMP/err") || RC=$?
}

new_calls()   { cat "$SCEN/.new_calls" 2>/dev/null || echo 0; }
ls_calls()    { cat "$SCEN/.ls_calls" 2>/dev/null || echo 0; }
stop_calls()  { cat "$SCEN/.stop.calls" 2>/dev/null || echo 0; }
state_file()  { printf '%s' "${RAILANS_STATE_FILE:-$ORCA_REPO_PATH/.railans-orca-state.json}"; }

# ---- case_00 静态 ------------------------------------------------------------
case_00() {
  printf '%s\n' "-- case_00 静态：bash -n / 执行位 / orca.yaml 条目形态"
  case_setup
  local bad=0 f
  for f in create.sh suspend.sh resume.sh destroy.sh; do
    bash -n "$SCRIPTS/$f" 2>"$TMP/err" && t_ok "bash -n $f" || { bad=1; t_fail "bash -n $f（$(cat "$TMP/err")）"; }
  done
  bash -n "$HERE/test-orca-recipe.sh" && t_ok "bash -n test-orca-recipe.sh 自身" || { bad=1; t_fail "bash -n 自身"; }
  ((bad == 1)) && return 0

  for f in create.sh suspend.sh resume.sh destroy.sh; do
    assert_file "$f 存在" "$SCRIPTS/$f" 存在
    [[ -x "$SCRIPTS/$f" ]] && t_ok "$f 可执行（doctor 查执行位）" || t_fail "$f 缺执行位（doctor 会 warn）"
  done

  local y
  y=$(cat "$YAML")
  assert_cont "orca.yaml 有 environmentRecipes 段" "environmentRecipes:" "$y"
  assert_cont "orca.yaml recipe id" "id: railans-box" "$y"
  if [[ "railans-box" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]; then
    t_ok "id 符合 ORCA_VM_RECIPE_ID_PATTERN"
  else
    t_fail "id 不符合 ORCA_VM_RECIPE_ID_PATTERN"
  fi
  assert_cont "orca.yaml create 命令" "create: ./scripts/create.sh" "$y"
  assert_cont "orca.yaml suspend 命令" "suspend: ./scripts/suspend.sh" "$y"
  assert_cont "orca.yaml resume 命令" "resume: ./scripts/resume.sh" "$y"
  assert_cont "orca.yaml destroy 命令" "destroy: ./scripts/destroy.sh" "$y"
  assert_cont "orca.yaml 带 (ephemeral) 名字提示" "(ephemeral)" "$y"
}

# ---- case_tc01 create 转换 + 结果契约 -----------------------------------------
case_tc01() {
  printf '%s\n' "-- case_tc01 create：boxView→connection JSON 逐字段 + 契约（TC1/TC7 垫片子集）"
  case_setup
  ORCA_VM_MODE=create run_script "$SCRIPTS/create.sh"
  assert_rc "create 退出码" 0 "$RC"
  assert_file "stdout 非空" "$TMP/out" 非空

  # 契约静态口径：stdout 恰好一个 JSON 对象
  python3 - "$TMP/out" <<'PY' && t_ok "stdout 恰好一个 JSON 对象（单行单对象）" \
    || t_fail "stdout 非恰好一个 JSON 对象"
import json, sys
raw = open(sys.argv[1]).read()
d = json.loads(raw)
assert isinstance(d, dict)
assert raw.count("\n") == 1
PY

  assert_eq "schemaVersion=1（默认 orca-worktree）" "1" "$(jget "$TMP/out" 'd["schemaVersion"]')"
  assert_eq "connection.type=ssh" "ssh" "$(jget "$TMP/out" 'd["connection"]["type"]')"
  assert_eq "target.label" "railans box-ab12cd" "$(jget "$TMP/out" 'd["connection"]["target"]["label"]')"
  assert_eq "target.host=boxView ssh_host" "ctl.example.org" "$(jget "$TMP/out" 'd["connection"]["target"]["host"]')"
  assert_eq "target.port=boxView ssh_port" "22001" "$(jget "$TMP/out" 'd["connection"]["target"]["port"]')"
  assert_eq "target.username=dev" "dev" "$(jget "$TMP/out" 'd["connection"]["target"]["username"]')"
  assert_eq "target.identityFile=钥匙绝对路径" "$TMP/provider_key" "$(jget "$TMP/out" 'd["connection"]["target"]["identityFile"]')"
  assert_eq "projectRoot=基目录+workspace 名分段（净化空格）" "/home/dev/orca/demo-workspace" "$(jget "$TMP/out" 'd["connection"]["projectRoot"]')"
  assert_eq "userData.provider" "railans" "$(jget "$TMP/out" 'd["userData"]["provider"]')"
  assert_eq "userData.box=boxView box" "box-ab12cd" "$(jget "$TMP/out" 'd["userData"]["box"]')"
  assert_eq "userData.expires=boxView expires" "2026-12-02T00:00:00Z" "$(jget "$TMP/out" 'd["userData"]["expires"]')"

  # target 字段集 strict（orca SshTarget schema 同构面）
  local tkeys
  tkeys=$(jget "$TMP/out" '",".join(sorted(d["connection"]["target"].keys()))')
  assert_eq "target 字段集 strict（无多余键）" "host,identityFile,label,port,username" "$tkeys"

  assert_eq "记锁：activeBox.workspaceId" "ws-1" "$(jget "$(state_file)" 'd["activeBox"]["workspaceId"]')"
  assert_eq "记锁：activeBox.box" "box-ab12cd" "$(jget "$(state_file)" 'd["activeBox"]["box"]')"
  assert_file "锁文件落在 repo 下" "$(state_file)" 存在

  assert_cont "垫片收到 new --json" "new --json" "$(cat "$FAKE_CTL_LOG")"
  assert_no "主路径不依赖 wait（垫片未被调）" " wait " "$(cat "$FAKE_CTL_LOG")"
}

# ---- case_tc02 create 错误透传与退避（TC2 垫片子集） ---------------------------
case_tc02() {
  printf '%s\n' "-- case_tc02 create 错误透传：code 上 stderr / retryable 退避 / 配额码不重试"
  case_setup
  local limit_env='{"error": {"code": "limit_per_key", "message": "this key already has a box (one key = one box)", "retryable": false}}'
  printf '%s\n' "$limit_env" >"$SCEN/new-error.json"
  printf '1\n' >"$SCEN/new-fail-times"      # 第 1 次（也是唯一一次）失败
  ORCA_VM_MODE=create run_script "$SCRIPTS/create.sh"
  assert_rc "配额码 exit 1" 1 "$RC"
  assert_cont "stderr 含 code" "limit_per_key" "$(cat "$TMP/err")"
  assert_cont "控制面文案透给用户" "already has a box" "$(cat "$TMP/err")"
  assert_eq "非 retryable 不重试（垫片只被调 1 次）" "1" "$(new_calls)"
  assert_file "失败不产出结果" "$TMP/out" 空
  assert_file "失败不记锁" "$(state_file)" 不存在

  case_setup
  cat >"$SCEN/new-error.json" <<'JSON'
{"error": {"code": "creating_in_progress", "message": "box box-ab12cd is still being created, retry in a few seconds", "box": "box-ab12cd", "retryable": true, "retry_after_seconds": 5}}
JSON
  printf '1\n' >"$SCEN/new-fail-times"      # 第 1 次失败，第 2 次成功
  ORCA_VM_MODE=create run_script "$SCRIPTS/create.sh"
  assert_rc "retryable 失败一次后重试成功" 0 "$RC"
  assert_eq "垫片被调 2 次" "2" "$(new_calls)"
  assert_cont "按 retry_after_seconds 退避（sleep 5）" "5" "$(cat "$FAKE_SLEEP_LOG")"
  assert_eq "重试成功后产出结果" "box-ab12cd" "$(jget "$TMP/out" 'd["userData"]["box"]')"

  case_setup
  cat >"$SCEN/new-error.json" <<'JSON'
{"error": {"code": "no_vm_node_available", "message": "no vm node available", "retryable": true}}
JSON
  printf '99\n' >"$SCEN/new-fail-times"     # 永远失败
  ORCA_VM_MODE=create run_script "$SCRIPTS/create.sh"
  assert_rc "持续 retryable 退避上限 3 次后失败" 1 "$RC"
  assert_eq "重试上限 3 次（垫片计数）" "3" "$(new_calls)"
  assert_cont "stderr 含末次 code" "no_vm_node_available" "$(cat "$TMP/err")"

  case_setup
  printf 'error: ssh: connection refused\n' >"$SCEN/new-error.json"
  printf '1\n' >"$SCEN/new-fail-times"
  ORCA_VM_MODE=create run_script "$SCRIPTS/create.sh"
  assert_rc "非信封输出（传输层失败）exit 1" 1 "$RC"
  assert_cont "stderr 指出非结构化错误" "结构化错误信封" "$(cat "$TMP/err")"
}

# ---- case_tc03 create 幂等复用（TC3） ------------------------------------------
case_tc03() {
  printf '%s\n' "-- case_tc03 create 幂等复用：stopped 态 boxView 仍产出可连接 target"
  case_setup
  cat >"$SCEN/new.json" <<'JSON'
{"box": "box-ab12cd", "state": "stopped", "node": "node-1", "vm_ip": "192.168.1.42", "ssh": "ssh -p 22001 dev@ctl.example.org", "ssh_port": 22001, "ssh_host": "ctl.example.org", "preview": "https://box-ab12cd.example.org", "expires": "2026-12-02T00:00:00Z", "shared": false}
JSON
  ORCA_VM_MODE=create run_script "$SCRIPTS/create.sh"
  assert_rc "stopped 态复用退出码 0（new 已拉起，无需 wait）" 0 "$RC"
  assert_eq "target.host" "ctl.example.org" "$(jget "$TMP/out" 'd["connection"]["target"]["host"]')"
  assert_eq "target.port" "22001" "$(jget "$TMP/out" 'd["connection"]["target"]["port"]')"
  assert_no "全程未调 wait" " wait " "$(cat "$FAKE_CTL_LOG")"
}

# ---- case_tc04 repo 本地锁（TC4 / §5.4） ---------------------------------------
case_tc04() {
  printf '%s\n' "-- case_tc04 本地锁：无锁→过 / 异 workspace→拒 / 同 workspace→过 / destroy 释放"

  case_setup
  ORCA_VM_MODE=create run_script "$SCRIPTS/create.sh"
  assert_rc "无锁 create 放行" 0 "$RC"
  assert_file "create 记锁" "$(state_file)" 存在

  case_setup
  printf '%s\n' '{"activeBox": {"box": "box-ab12cd", "workspaceId": "ws-other", "acquiredAt": "2026-11-25T00:00:00+00:00"}}' >"$(state_file)"
  ORCA_VM_MODE=create run_script "$SCRIPTS/create.sh"
  assert_rc "异 workspace 持锁→拒绝" 1 "$RC"
  assert_cont "文案点名持有者 workspace" "ws-other" "$(cat "$TMP/err")"
  assert_cont "文案给 stale 锁手工清除指引（state 文件路径）" "$(state_file)" "$(cat "$TMP/err")"
  assert_cont "文案点名 activeBox 字段" "activeBox" "$(cat "$TMP/err")"
  assert_eq "拒绝路径不触控制面（垫片零调用）" "0" "$(new_calls)"

  case_setup
  printf '%s\n' '{"activeBox": {"box": "box-ab12cd", "workspaceId": "ws-1", "acquiredAt": "2026-11-25T00:00:00+00:00"}}' >"$(state_file)"
  ORCA_VM_MODE=create run_script "$SCRIPTS/create.sh"
  assert_rc "同 workspace 重放→放行" 0 "$RC"
  assert_eq "重放后锁仍在（workspace 不变）" "ws-1" "$(jget "$(state_file)" 'd["activeBox"]["workspaceId"]')"

  case_setup
  printf '%s\n' '{"activeBox": {"box": "box-ab12cd", "workspaceId": "ws-1", "acquiredAt": "2026-11-25T00:00:00+00:00"}}' >"$(state_file)"
  ORCA_VM_MODE=destroy run_script "$SCRIPTS/destroy.sh" <"$TMP/payload.json"
  assert_rc "destroy 放行" 0 "$RC"
  assert_file "destroy 释放锁" "$(state_file)" 不存在
}

# ---- case_tc05 suspend（TC5 前半） ----------------------------------------------
case_tc05() {
  printf '%s\n' "-- case_tc05 suspend：payload 提取 userData.box → stop <box>；缺键→拒"
  case_setup
  ORCA_VM_MODE=suspend run_script "$SCRIPTS/suspend.sh" <"$TMP/payload.json"
  assert_rc "suspend 退出码" 0 "$RC"
  assert_cont "垫片收到 stop <box>（payload 回传定位）" "stop box-ab12cd" "$(cat "$FAKE_CTL_LOG")"
  assert_file "suspend stdout 无契约保持干净" "$TMP/out" 空

  case_setup
  printf '%s\n' '{"schemaVersion":1,"mode":"suspend","recipeId":"railans-box","recipeResult":{"userData":{}}}' >"$TMP/payload.json"
  ORCA_VM_MODE=suspend run_script "$SCRIPTS/suspend.sh" <"$TMP/payload.json"
  assert_rc "payload 缺 userData.box→失败" 1 "$RC"
  assert_cont "stderr 指出缺键" "userData.box" "$(cat "$TMP/err")"
  assert_eq "缺键不触控制面" "0" "$(stop_calls)"
}

# ---- case_tc06 resume（TC5 后半） -----------------------------------------------
case_tc06() {
  printf '%s\n' "-- case_tc06 resume：start→重发新鲜 JSON；not-found→回退 create；其他失败透传"

  case_setup
  cat >"$SCEN/ls.json" <<'JSON'
[{"name": "box-ab12cd", "node": "node-1", "ip": "192.168.1.42", "port": 22001, "state": "running", "expires": "2026-12-09T00:00:00Z"}]
JSON
  ORCA_VM_MODE=resume run_script "$SCRIPTS/resume.sh" <"$TMP/payload.json"
  assert_rc "resume 退出码" 0 "$RC"
  assert_cont "垫片收到 start <box>" "start box-ab12cd" "$(cat "$FAKE_CTL_LOG")"
  assert_cont "垫片收到 ls --json（刷新 expires）" "ls --json" "$(cat "$FAKE_CTL_LOG")"
  assert_eq "重发 schemaVersion=1" "1" "$(jget "$TMP/out" 'd["schemaVersion"]')"
  assert_eq "target.host 保持" "ctl.example.org" "$(jget "$TMP/out" 'd["connection"]["target"]["host"]')"
  assert_eq "target.port 保持" "22001" "$(jget "$TMP/out" 'd["connection"]["target"]["port"]')"
  assert_eq "expires 已刷新（ls 罐头值）" "2026-12-09T00:00:00Z" "$(jget "$TMP/out" 'd["userData"]["expires"]')"
  assert_eq "identityFile 以当前钥匙为准（不回传 payload 旧路径）" "$TMP/provider_key" "$(jget "$TMP/out" 'd["connection"]["target"]["identityFile"]')"
  assert_eq "userData.box 回传" "box-ab12cd" "$(jget "$TMP/out" 'd["userData"]["box"]')"

  case_setup
  printf 'box "box-ab12cd" not found\n' >"$SCEN/start.out"
  printf '1\n' >"$SCEN/start.rc"
  ORCA_VM_MODE=resume run_script "$SCRIPTS/resume.sh" <"$TMP/payload.json"
  assert_rc "start not-found→回退 create 成功" 0 "$RC"
  assert_cont "垫片先 start 后 new" "start box-ab12cd" "$(cat "$FAKE_CTL_LOG")"
  assert_cont "垫片收到回退 new --json" "new --json" "$(cat "$FAKE_CTL_LOG")"
  assert_cont "stderr 明示重建与数据口径" "全新空箱" "$(cat "$TMP/err")"
  assert_eq "重建后结果箱名确定性同名" "box-ab12cd" "$(jget "$TMP/out" 'd["userData"]["box"]')"
  assert_eq "重建后 expires 取自新 boxView" "2026-12-02T00:00:00Z" "$(jget "$TMP/out" 'd["userData"]["expires"]')"
  assert_file "重建路径重记锁" "$(state_file)" 存在

  case_setup
  printf 'error: incus start failed\n' >"$SCEN/start.out"
  printf '1\n' >"$SCEN/start.rc"
  ORCA_VM_MODE=resume run_script "$SCRIPTS/resume.sh" <"$TMP/payload.json"
  assert_rc "start 其他失败→透传失败" 1 "$RC"
  assert_file "失败不产出结果" "$TMP/out" 空
  assert_eq "失败路径不回退 create" "0" "$(new_calls)"
}

# ---- case_tc07 userData 回传闭环（§1.2 契约） ------------------------------------
case_tc07() {
  printf '%s\n' "-- case_tc07 userData 回传闭环：create 输出→payload→suspend/destroy 定位箱名"
  case_setup
  ORCA_VM_MODE=create run_script "$SCRIPTS/create.sh"
  assert_rc "create 退出码" 0 "$RC"
  # 用 create 的真实输出组装 lifecycle payload（orca runner 即原样回传 recipeResult）
  python3 - "$TMP/out" "$TMP/payload.json" <<'PY' && t_ok "payload 由 create 输出组装" \
    || t_fail "payload 组装失败"
import json, sys
result = json.loads(open(sys.argv[1]).read())
payload = {
    "schemaVersion": 1, "mode": "destroy", "recipeId": "railans-box",
    "instanceId": "orca-0001", "projectId": "proj-1",
    "workspaceId": "ws-1", "workspaceName": "demo workspace",
    "recipeResult": result,
}
json.dump(payload, open(sys.argv[2], "w"))
PY
  ORCA_VM_MODE=suspend run_script "$SCRIPTS/suspend.sh" <"$TMP/payload.json"
  assert_rc "suspend 靠回传定位箱名" 0 "$RC"
  assert_cont "垫片收到 create 产出的箱名（stop）" "stop box-ab12cd" "$(cat "$FAKE_CTL_LOG")"
  ORCA_VM_MODE=destroy run_script "$SCRIPTS/destroy.sh" <"$TMP/payload.json"
  assert_rc "destroy 靠回传定位箱名" 0 "$RC"
  assert_cont "垫片收到 create 产出的箱名（rm）" "rm box-ab12cd" "$(cat "$FAKE_CTL_LOG")"
}

# ---- case_tc08 destroy（TC6） ----------------------------------------------------
case_tc08() {
  printf '%s\n' "-- case_tc08 destroy：rm+ls 复核 / deleting 尾巴重试 / 复核超限 / not-found 容忍"

  case_setup
  ORCA_VM_MODE=destroy run_script "$SCRIPTS/destroy.sh" <"$TMP/payload.json"
  assert_rc "rm 成功 + ls 已净→退出码 0" 0 "$RC"
  assert_cont "垫片收到 rm <box>" "rm box-ab12cd" "$(cat "$FAKE_CTL_LOG")"
  assert_cont "垫片收到 ls --json 复核" "ls --json" "$(cat "$FAKE_CTL_LOG")"
  assert_file "destroy stdout 无契约保持干净" "$TMP/out" 空

  case_setup   # deleting 尾巴：ls 前 2 次仍见箱，第 3 次消失
  cat >"$SCEN/ls.json" <<'JSON'
[{"name": "box-ab12cd", "node": "node-1", "ip": "192.168.1.42", "port": 22001, "state": "deleting", "expires": "2026-12-02T00:00:00Z"}]
JSON
  printf '2\n' >"$SCEN/ls-gone-after"
  ORCA_VM_MODE=destroy run_script "$SCRIPTS/destroy.sh" <"$TMP/payload.json"
  assert_rc "复核重试收敛→退出码 0" 0 "$RC"
  assert_eq "ls 共 3 次（2 次仍在 + 1 次已净）" "3" "$(ls_calls)"

  case_setup   # 永不收敛
  cat >"$SCEN/ls.json" <<'JSON'
[{"name": "box-ab12cd", "node": "node-1", "ip": "192.168.1.42", "port": 22001, "state": "deleting", "expires": "2026-12-02T00:00:00Z"}]
JSON
  ORCA_VM_MODE=destroy run_script "$SCRIPTS/destroy.sh" <"$TMP/payload.json"
  assert_rc "复核超限→exit 非 0（orca 记 cleanup_failed 可重试）" 1 "$RC"
  assert_eq "复核上限 12 次（≈60s）" "12" "$(ls_calls)"
  assert_cont "stderr 给出兜底口径" "TTL 终删兜底" "$(cat "$TMP/err")"

  case_setup   # orca 侧连接失败自动补跑 destroy 时箱可能已不存在
  printf 'box "box-ab12cd" not found\n' >"$SCEN/rm.out"
  printf '1\n' >"$SCEN/rm.rc"
  ORCA_VM_MODE=destroy run_script "$SCRIPTS/destroy.sh" <"$TMP/payload.json"
  assert_rc "rm not-found 容忍为成功" 0 "$RC"
  assert_cont "stderr 明示容忍口径" "已不存在" "$(cat "$TMP/err")"
}

# ---- case_tc09 检出模式守卫（TC10） ----------------------------------------------
case_tc09() {
  printf '%s\n' "-- case_tc09 检出模式守卫：schemaVersion 2 显式拒绝"
  case_setup
  ORCA_VM_MODE=create ORCA_RECIPE_RESULT_SCHEMA_VERSION=2 run_script "$SCRIPTS/create.sh"
  assert_rc "schemaVersion 2→exit 非 0" 1 "$RC"
  assert_cont "stderr 点明仅支持 orca-worktree" "orca-worktree" "$(cat "$TMP/err")"
  assert_eq "守卫在触控制面之前（垫片零调用）" "0" "$(new_calls)"

  case_setup
  ORCA_VM_MODE=suspend run_script "$SCRIPTS/suspend.sh" <"$TMP/payload.json"
  assert_rc "suspend 正常路径不受影响（对照组）" 0 "$RC"
}

# ---- case_tc10 环境面（必填缺失 / 路径归一化 / 透传断言） -------------------------
case_tc10() {
  printf '%s\n' "-- case_tc10 环境面：env 缺失快速失败 / 钥匙路径归一化 / ctl 透传"

  case_setup
  RAILANS_PROVIDER_KEY= ORCA_VM_MODE=create run_script "$SCRIPTS/create.sh"
  assert_rc "缺 RAILANS_PROVIDER_KEY→快速失败" 1 "$RC"
  assert_cont "stderr 点名变量" "RAILANS_PROVIDER_KEY" "$(cat "$TMP/err")"
  assert_eq "未触控制面" "0" "$(new_calls)"

  case_setup
  RAILANS_CTL_HOST= ORCA_VM_MODE=create run_script "$SCRIPTS/create.sh"
  assert_rc "缺 RAILANS_CTL_HOST→快速失败" 1 "$RC"
  assert_cont "stderr 点名变量" "RAILANS_CTL_HOST" "$(cat "$TMP/err")"

  case_setup
  RAILANS_CTL_PORT= ORCA_VM_MODE=create run_script "$SCRIPTS/create.sh"
  assert_rc "缺 RAILANS_CTL_PORT→快速失败" 1 "$RC"
  assert_cont "stderr 点名变量" "RAILANS_CTL_PORT" "$(cat "$TMP/err")"

  case_setup
  RAILANS_PROVIDER_KEY="$TMP/no-such-key" ORCA_VM_MODE=create run_script "$SCRIPTS/create.sh"
  assert_rc "钥匙文件不存在→快速失败" 1 "$RC"
  assert_cont "stderr 给出路径" "$TMP/no-such-key" "$(cat "$TMP/err")"

  case_setup   # 相对路径 → 以调用方 cwd（运行时=repo 根）归一为绝对路径
  : >"$TMP/repo/relkey"
  RAILANS_PROVIDER_KEY=relkey ORCA_VM_MODE=create run_script_in "$TMP/repo" "$SCRIPTS/create.sh"
  assert_rc "相对钥匙路径 create 放行" 0 "$RC"
  assert_eq "identityFile 归一为绝对路径" "$TMP/repo/relkey" "$(jget "$TMP/out" 'd["connection"]["target"]["identityFile"]')"
  assert_cont "ssh -i 收到绝对路径" "-i $TMP/repo/relkey" "$(cat "$FAKE_CTL_LOG")"

  case_setup   # ~/ 前缀展开（ssh -i 不做 ~ 展开，脚本代做）
  mkdir -p "$TMP/keys"
  : >"$TMP/keys/provider_key"
  RAILANS_PROVIDER_KEY='~/keys/provider_key' ORCA_VM_MODE=create run_script "$SCRIPTS/create.sh"
  assert_rc "~/ 钥匙路径 create 放行" 0 "$RC"
  assert_eq "identityFile 展开 HOME" "$TMP/keys/provider_key" "$(jget "$TMP/out" 'd["connection"]["target"]["identityFile"]')"

  case_setup   # ctl 地址/端口/钥匙路径透传（垫片 argv 全量断言）
  ORCA_VM_MODE=create run_script "$SCRIPTS/create.sh"
  local log; log=$(cat "$FAKE_CTL_LOG")
  assert_cont "ctl 主机透传（git@<host> 形态）" "git@ctl.example.org" "$log"
  assert_cont "ctl 端口透传（-p 2222）" "-p 2222" "$log"
  assert_cont "钥匙路径透传（-i <abs>）" "-i $TMP/provider_key" "$log"
  assert_cont "子命令透传（new --json）" "new --json" "$log"

  case_setup
  ORCA_VM_MODE=suspend run_script "$SCRIPTS/suspend.sh" <"$TMP/payload.json"
  log=$(cat "$FAKE_CTL_LOG")
  assert_cont "suspend 同样透传主机/端口/钥匙" "-p 2222" "$log"
  assert_cont "suspend 透传钥匙路径" "-i $TMP/provider_key" "$log"
  assert_cont "suspend 子命令透传" "stop box-ab12cd" "$log"

  case_setup   # ORCA_VM_MODE 守卫
  ORCA_VM_MODE=suspend run_script "$SCRIPTS/create.sh"
  assert_rc "模式不符（create 收到 suspend）→拒绝" 1 "$RC"
  assert_cont "stderr 点名 ORCA_VM_MODE" "ORCA_VM_MODE" "$(cat "$TMP/err")"
}

printf '%s\n' "== orca 形态⑤ recipe 垫片测试组（scripts/tests/test-orca-recipe.sh，全垫片零网络）=="
for case_fn in case_00 case_tc01 case_tc02 case_tc03 case_tc04 case_tc05 \
               case_tc06 case_tc07 case_tc08 case_tc09 case_tc10; do
  "$case_fn"
done
cleanup

printf '\n'
if ((FAIL > 0)); then
  printf '结论：FAIL（%d 断言过 / %d 断言败）\n' "$PASS" "$FAIL"
  exit 1
fi
printf '结论：PASS（%d 断言全过）\n' "$PASS"
exit 0
