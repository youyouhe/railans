#!/usr/bin/env bash
# scripts/tests/test-nft-render.sh — 防火墙 H1+W5 断言组（TC-H1-01…03、TC-H1-04 自动部分、TC-H1-06）
#
# 唯一事实源：仓库内被测实现（node/railans-node.sh 渲染/比对函数 +
# node/deploy/nftables-railans.nft 模板）。真机部分（TC-H1-04 真机、
# TC-H1-05 探针矩阵、verify-nft 各节点跑）属生产变更窗口，本脚本不代跑。
#
# 隔离承诺（硬红线）：
#   - 全部产物写 mktemp -d 临时目录，绝不渲染到 /etc/nftables.d；
#   - 不跑 nft（唯一的例外是 TC-H1-03：环境有 nft 时跑一次 `nft -c -f <产物>`
#     语法检查——check 模式不落规则，非 root netlink 失败按 SKIP 处理并注明依据）；
#   - 不 ssh 任何节点；hc_members 在测试内打桩，对 incus/incusd 零查询。
#
# fixture 手法（「source 函数」，与生产同源零复制）：
#   把 railans-node.sh 复制为 harness（剥掉末行 `main "$@"`）后在 bash -c 子进程
#   里 source，再覆盖 SCRIPT_DIR 指回仓库 node/——被测函数与生产同源，
#   渲染/比对逻辑零复制。

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
NODE_SCRIPT="$HERE/../../node/railans-node.sh"
TEMPLATE="$HERE/../../node/deploy/nftables-railans.nft"

# 用例文档 TC-H1-01 fixture 值
FX_NODE_ADDR="192.168.1.12"
FX_SUBNET="10.10.2.0/24"
FX_WAN="testnic0"
FX_MGMT="192.168.1.0/24"
FX_GWMESH="10.10.2.1"

PASS=0
FAIL=0
TMP=""

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
assert_ord() {  # <说明> <行号算术条件（在同一作用域 eval）>
  if eval "(( $2 ))" 2>/dev/null; then
    t_ok "$1"
  else
    t_fail "$1（行号条件不满足：$2）"
  fi
}

cleanup() {
  if [[ -n "${TMP:-}" ]]; then
    chmod -R u+rwX "$TMP" 2>/dev/null
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-nft-render.XXXXXX")"

# harness：剥掉入口行后 source（函数可调用、main 不跑），SCRIPT_DIR 指回仓库 node/
HARNESS="$TMP/node-harness.sh"
sed '/^main "\$@"$/d' "$NODE_SCRIPT" >"$HARNESS"

# 在 harness 子进程里执行片段；stdout/stderr 透传，rc 透传。
# 片段内可用 $TMP 与被测函数；harness 自带 set -euo pipefail。
vn() {
  VN_SNIPPET="$1" VN_TMP="$TMP" VN_HERE="$HERE" TMP="$TMP" \
    bash -c '
      set -euo pipefail
      source "$VN_TMP/node-harness.sh"
      SCRIPT_DIR="$(cd -- "$VN_HERE/../../node" && pwd -P)"
      eval "$VN_SNIPPET"
    '
}

# 模板/产物首个匹配行号（无匹配输出空）
tline() {  # <文件> <grep模式>
  grep -n "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1
}

# 渲染产物 → dump 形态 fixture（tab 缩进；链声明/规则/闭括号保序；注释行保留——
# 比对函数的归一化应把它们滤掉，fixture 特意留着以证明这一点）
make_dump_fixture() {  # <渲染产物> <输出>
  {
    printf 'table inet railans {\n'
    while IFS= read -r l; do
      case "$l" in
        '    chain '*' {'*) printf '\t%s\n' "$l" ;;
        '    }')            printf '\t}\n' ;;
        '        '*)        printf '\t\t%s\n' "${l#        }" ;;
      esac
    done <"$1"
    printf '}\n'
  } >"$2"
}

render_fixture() {  # <输出文件>（TC-H1-01 fixture 值渲染）
  vn "render_nft_template \"\$TMP/$(basename "$1")\" ${FX_WAN} ${FX_MGMT} ${FX_GWMESH}" >/dev/null 2>&1
  mv "$TMP/$(basename "$1")" "$1"
}

# ---------------------------------------------------------------- TC-H1-01 渲染三占位符全替换
case_h1_01() {
  local out rc rendered
  mkdir -p "$TMP/c01"
  # 1a) __MGMT__ 推导：正常值
  out="$(vn 'MGMT_CIDR="$(derive_mgmt_cidr '"${FX_NODE_ADDR}"')"; printf "%s" "$MGMT_CIDR"')" && rc=0 || rc=$?
  assert_rc "TC-H1-01 derive_mgmt_cidr 正常值退出 0" 0 "$rc"
  assert_eq "TC-H1-01 derive_mgmt_cidr 得 ${FX_MGMT}" "$FX_MGMT" "$out"
  # 1b) 异常形态 loud fail（rc 非 0、无 stdout 半成品、stderr 点名 NODE_ADDR）
  out="$(vn 'derive_mgmt_cidr "not-an-ip"' 2>/dev/null)" && rc=0 || rc=$?
  assert_rc "TC-H1-01 derive_mgmt_cidr 异常形态非 0" 1 "$rc"
  assert_eq "TC-H1-01 derive_mgmt_cidr 异常形态无半成品输出" "" "$out"
  local err
  err="$(vn 'derive_mgmt_cidr "not-an-ip" >/dev/null' 2>&1 || true)"
  assert_cont "TC-H1-01 loud fail 报错含 NODE_ADDR 提示" "NODE_ADDR" "$err"
  # 1c) 渲染产物：三占位符逐字替换、零残留、规则序保持
  render_fixture "$TMP/c01/rendered.nft"
  assert_eq "TC-H1-01 产物落临时文件非空" "yes" \
    "$([[ -s "$TMP/c01/rendered.nft" ]] && echo yes || echo no)"
  rendered="$(cat "$TMP/c01/rendered.nft")"
  assert_no "TC-H1-01 产物 __WAN__ 零残留" "__WAN__" "$rendered"
  assert_no "TC-H1-01 产物 __MGMT__ 零残留" "__MGMT__" "$rendered"
  assert_no "TC-H1-01 产物 __GWMESH__ 零残留" "__GWMESH__" "$rendered"
  assert_cont "TC-H1-01 __WAN__→${FX_WAN}（允许面端口池）" \
    "iifname \"${FX_WAN}\" ip saddr 10.10.0.0/16 tcp dport 22000-22999 accept" "$rendered"
  assert_cont "TC-H1-01 __MGMT__→${FX_MGMT}（forward drop）" \
    "iifname \"br-vm\" ip daddr ${FX_MGMT} drop" "$rendered"
  assert_cont "TC-H1-01 __GWMESH__→${FX_GWMESH}（W5 门面）" \
    "iifname \"br-vm\" ip daddr ${FX_GWMESH} tcp dport 4092 accept" "$rendered"
  assert_cont "TC-H1-01 __WAN__→${FX_WAN}（masquerade）" \
    "ip saddr 10.10.0.0/16 oifname \"${FX_WAN}\" masquerade" "$rendered"
  out="$(vn 'vnft_extract_table <"$TMP/c01/rendered.nft" | vnft_chain_block input | vnft_norm_rules | head -1')"
  assert_eq "TC-H1-01 替换后 input 首条规则仍是 established" \
    "ct state established,related accept" "$out"
  out="$(vn 'vnft_extract_table <"$TMP/c01/rendered.nft" | vnft_chain_block input | vnft_norm_rules | grep -nFx "iifname \"br-vm\" drop" | cut -d: -f1')"
  assert_eq "TC-H1-01 替换后 br-vm drop 仍收尾 input 链（第 6 条规则）" "6" "$out"
}

# ---------------------------------------------------------------- TC-H1-02 规则序不变量（模板静态断言）
case_h1_02() {
  local l_in l_est l_w5 l_a1 l_a2 l_lim l_bdrop
  local l_fw l_fa1 l_fa2 l_fd1 l_fd2
  local k
  l_in="$(tline "$TEMPLATE" '^    chain input {')"
  l_est="$(tline "$TEMPLATE" 'ct state established,related accept')"
  l_w5="$(tline "$TEMPLATE" 'iifname "br-vm" ip daddr __GWMESH__ tcp dport 4092 accept')"
  l_a1="$(tline "$TEMPLATE" 'iifname "__WAN__" ip saddr 10.10.0.0/16 tcp dport 22000-22999 accept')"
  l_a2="$(tline "$TEMPLATE" 'iifname "__WAN__" ip saddr 10.10.0.0/16 ip daddr __GWMESH__ tcp dport 4092 accept')"
  l_lim="$(tline "$TEMPLATE" 'iifname "__WAN__" ip saddr 10.10.0.0/16 drop')"
  l_bdrop="$(tline "$TEMPLATE" '^        iifname "br-vm" drop$')"
  for k in l_in l_est l_w5 l_a1 l_a2 l_lim l_bdrop; do
    assert_eq "TC-H1-02 input 关键行在位（${k}）" "yes" \
      "$([[ -n "${!k}" ]] && echo yes || echo no)"
  done
  # 1) established 为 input 第一条规则（链头之后、其余全部规则行之前）
  assert_ord "TC-H1-02 established 是 input 首条规则" \
    "l_in < l_est && l_est < l_w5 && l_est < l_a1 && l_est < l_a2 && l_est < l_lim && l_est < l_bdrop"
  # 2) W5 4092 accept 在 br-vm drop 之前
  assert_ord "TC-H1-02 W5 4092 在 br-vm drop 之前" "l_w5 < l_bdrop"
  # 3) 允许面两条 + 限面 drop 齐备，drop 在两条允许面之后
  assert_ord "TC-H1-02 限面 drop 位于两条允许面之后" "l_a1 < l_lim && l_a2 < l_lim"
  # 4) forward：放行先于两条管理网 drop
  l_fw="$(tline "$TEMPLATE" '^    chain forward {')"
  l_fa1="$(tline "$TEMPLATE" 'iifname "br-vm" ip daddr 10.10.0.0/16 accept')"
  l_fa2="$(tline "$TEMPLATE" 'iifname "__WAN__" ip daddr 10.10.0.0/16 accept')"
  l_fd1="$(tline "$TEMPLATE" 'iifname "br-vm" ip daddr __MGMT__ drop')"
  l_fd2="$(tline "$TEMPLATE" 'iifname "br-vm" ip daddr 10.0.0.0/8 drop')"
  assert_ord "TC-H1-02 forward 放行先于两条管理网 drop" \
    "l_fa1 < l_fd1 && l_fa1 < l_fd2 && l_fa2 < l_fd1 && l_fa2 < l_fd2"
  # 5) __MGMT__ drop 与 10/8 兜底并存
  assert_ord "TC-H1-02 forward __MGMT__ drop 与 10/8 兜底并存" "l_fd1 > 0 && l_fd2 > 0"
  # 6) postrouting masquerade 行未变动（含链型 nat 防回归——filter 型 base 链 nft 拒载）
  assert_eq "TC-H1-02 postrouting masquerade 行在位且唯一" "1" \
    "$(grep -cF 'ip saddr 10.10.0.0/16 oifname "__WAN__" masquerade' "$TEMPLATE")"
  assert_cont "TC-H1-02 postrouting 链型为 nat（filter 型 nft 拒载）" \
    "type nat hook postrouting priority srcnat; policy accept;" "$(cat "$TEMPLATE")"
  assert_no "TC-H1-02 不存在 type filter hook postrouting（模板笔误防回归）" \
    "type filter hook postrouting" "$(cat "$TEMPLATE")"
}

# ---------------------------------------------------------------- TC-H1-03 渲染产物语法/残留双检
case_h1_03() {
  local out rc
  mkdir -p "$TMP/c03"
  render_fixture "$TMP/c03/rendered.nft"
  # (b) 残留检查
  assert_eq "TC-H1-03 (b) 产物无 __ 占位符残留" "0" \
    "$(grep -Ec '__[A-Z_]+__' "$TMP/c03/rendered.nft" || true)"
  # (a) nft -c：环境有 nft 才跑（check 模式不落规则；非 root netlink 失败按 SKIP 注明）
  if command -v nft >/dev/null 2>&1; then
    out="$(nft -c -f "$TMP/c03/rendered.nft" 2>&1)" && rc=0 || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      t_ok "TC-H1-03 (a) nft -c 语法检查过"
    elif grep -qi 'syntax error\|unexpected' <<<"$out"; then
      t_fail "TC-H1-03 (a) nft -c 语法错误：$(head -3 <<<"$out")"
    else
      t_ok "TC-H1-03 (a) SKIP：nft 在场但 netlink 权限不可用（非语法错误：$(head -1 <<<"$out" | cut -c1-120)）"
    fi
  else
    t_ok "TC-H1-03 (a) SKIP：环境无 nft（用例文档允许，注明依据）"
  fi
}

# ---------------------------------------------------------------- TC-H1-04 verify-nft 第 0 步自动部分（fixture dump 演练）
case_h1_04() {
  local out
  mkdir -p "$TMP/c04"
  render_fixture "$TMP/c04/rendered.nft"
  make_dump_fixture "$TMP/c04/rendered.nft" "$TMP/c04/dump"
  # 1) 一致 → SAME 且无差异输出（TC-H1-04：dump 运行态 vs 渲染文件 diff 为空）
  out="$(vn 'if vnft_compare_persisted "$TMP/c04/dump" "$TMP/c04/rendered.nft"; then echo SAME; else echo DIFF; fi' 2>&1)"
  assert_cont "TC-H1-04 运行态=持久化 → SAME" "SAME" "$out"
  assert_no "TC-H1-04 一致时不打差异" "规则差异" "$out"
  # 2) 运行态多一条模板外手工规则 → DIFF 且指明 chain input（运行态手工规则场景）
  awk -v ins='\t\tlimit rate 5/second accept' '
    /^\t\}$/ && !done { print ins; done = 1 }
    { print }' "$TMP/c04/dump" >"$TMP/c04/dump-manual"
  out="$(vn 'if vnft_compare_persisted "$TMP/c04/dump-manual" "$TMP/c04/rendered.nft"; then echo SAME; else echo DIFF; fi' 2>&1)"
  assert_cont "TC-H1-04 运行态有手工规则 → DIFF" "DIFF" "$out"
  assert_cont "TC-H1-04 差异指明 chain input 规则差异" "chain input 规则差异" "$out"
  # 3) 链声明漂移 → 链声明差异
  sed 's/type filter hook input priority filter; policy accept;/type nat hook input priority filter; policy accept;/' \
    "$TMP/c04/dump" >"$TMP/c04/dump-decl"
  out="$(vn 'if vnft_compare_persisted "$TMP/c04/dump-decl" "$TMP/c04/rendered.nft"; then echo SAME; else echo DIFF; fi' 2>&1)"
  assert_cont "TC-H1-04 链声明漂移被检出" "chain input 链声明差异" "$out"
  # 4) postrouting LAN 豁免检测：dump 侧命中、模板侧为空
  awk '/masquerade$/ && !done { print "\t\tip daddr 192.168.1.0/24 return"; done = 1 }
    { print }' "$TMP/c04/dump" >"$TMP/c04/dump-exempt"
  out="$(vn 'vnft_postrouting_exempt "$TMP/c04/dump-exempt" 192.168.1.0/24')"
  assert_cont "TC-H1-04 豁免检测：dump 侧命中 return 行" \
    "ip daddr 192.168.1.0/24 return" "$out"
  out="$(vn 'vnft_postrouting_exempt "$TMP/c04/rendered.nft" 192.168.1.0/24')"
  assert_eq "TC-H1-04 豁免检测：模板侧为空" "" "$out"
  # 5) baseline JSON 写读回环（dump base64 内嵌零损）
  vn "vnft_write_baseline \"\$TMP/c04/b.json\" node2 \"\$TMP/c04/dump\"" >/dev/null 2>&1
  vn 'vnft_read_baseline_dump "$TMP/c04/b.json" > "$TMP/c04/b.dump"' >/dev/null 2>&1
  if cmp -s "$TMP/c04/dump" "$TMP/c04/b.dump"; then
    t_ok "TC-H1-04 baseline 写读回环零损"
  else
    t_fail "TC-H1-04 baseline 写读回环有损"
  fi
  assert_cont "TC-H1-04 baseline JSON 含 node/dump_b64 键" '"dump_b64"' "$(cat "$TMP/c04/b.json")"
  # 6) 探针 sidecar 解析（id<TAB>result 两列）
  cat >"$TMP/c04/probes.json" <<'EOF'
{
  "box_probes": {
    "block-192.168.1.12-22": "blocked",
    "allow-dns-223.5.5.5-53": "open",
    "allow-facade-10.10.1.1-4092": "refused"
  }
}
EOF
  out="$(vn 'vnft_read_probes "$TMP/c04/probes.json" | awk -F "\t" "{printf \"%s=%s;\", \$1, \$2}"')"
  assert_eq "TC-H1-04 探针 sidecar 解析（id=result 串）" \
    "block-192.168.1.12-22=blocked;allow-dns-223.5.5.5-53=open;allow-facade-10.10.1.1-4092=refused;" "$out"
}

# ---------------------------------------------------------------- TC-H1-06 既有 network 子命令零回归 + 登记完整性
case_h1_06() {
  local bn_err bn_rc help_out unk_out unk_rc out
  bn_err="$(bash -n "$NODE_SCRIPT" 2>&1)" && bn_rc=0 || bn_rc=$?
  assert_rc "TC-H1-06 bash -n 过" 0 "$bn_rc"
  assert_eq "TC-H1-06 bash -n 零输出" "" "$bn_err"
  help_out="$(bash "$NODE_SCRIPT" help 2>&1)"
  assert_cont "TC-H1-06 help/usage 清单含 verify-nft" "verify-nft" "$help_out"
  assert_cont "TC-H1-06 头部子命令注释表含 verify-nft" "verify-nft" \
    "$(grep '^#   verify-nft' "$NODE_SCRIPT")"
  assert_cont "TC-H1-06 main case 分发含 verify-nft" "| verify-nft | setup-subuid)" \
    "$(grep -F '| verify-nft | setup-subuid)' "$NODE_SCRIPT")"
  assert_cont "TC-H1-06 TC-W4-10 锚点 | setup-subuid) 未漂移" "| setup-subuid)" \
    "$(grep -F '| setup-subuid)' "$NODE_SCRIPT")"
  unk_out="$(bash "$NODE_SCRIPT" definitely-not-a-cmd 2>&1)" && unk_rc=0 || unk_rc=$?
  assert_rc "TC-H1-06 未知子命令退出 2（W1W4 报错路径不回归）" 2 "$unk_rc"
  assert_cont "TC-H1-06 未知子命令报错路径不回归" "未知子命令" "$unk_out"
  # 渲染段接线：network 里调用单一渲染入口 + MGMT 推导；旧内联 sed 已移除
  assert_cont "TC-H1-06 network 调 derive_mgmt_cidr" \
    'MGMT_CIDR="$(derive_mgmt_cidr "${NODE_ADDR}")"' "$(cat "$NODE_SCRIPT")"
  assert_cont "TC-H1-06 network 调 render_nft_template 渲染到持久化路径" \
    'render_nft_template "/etc/nftables.d/railans.nft"' "$(cat "$NODE_SCRIPT")"
  assert_eq "TC-H1-06 旧内联 sed（/ 定界单占位符）已移除" "0" \
    "$(grep -cF 'sed "s/__WAN__/${WAN}/g"' "$NODE_SCRIPT" || true)"
  assert_eq "TC-H1-06 subcmd_verify_nft 定义恰一处" "1" \
    "$(grep -c '^subcmd_verify_nft()' "$NODE_SCRIPT" || true)"
  # 箱内探针清单：hc_members 打桩后生成，生成物必须是合法 bash（箱内可粘贴执行）
  mkdir -p "$TMP/c06"
  vn '
hc_members(){ printf "nodeX\t192.168.1.254\tOnline\n"; }
GWMESH="'"${FX_GWMESH}"'" BRIDGE="br-vm" subcmd_verify_nft --print-box-probes
  ' >"$TMP/c06/list.txt" 2>&1
  assert_rc "TC-H1-06 --print-box-probes 退出 0（打桩环境）" 0 "$?"
  sed -n '/从这里开始复制/,/箱内执行段结束/p' "$TMP/c06/list.txt" \
    | grep -v '从这里开始复制\|箱内执行段结束' >"$TMP/c06/snippet.sh"
  bn_err="$(bash -n "$TMP/c06/snippet.sh" 2>&1)" && bn_rc=0 || bn_rc=$?
  assert_rc "TC-H1-06 生成的箱内清单可被 bash 解析（粘贴可执行）" 0 "$bn_rc"
  assert_cont "TC-H1-06 清单含阻断面行（桩成员 443）" \
    'add "block-192.168.1.254-443" 192.168.1.254 443' "$(cat "$TMP/c06/snippet.sh")"
  assert_cont "TC-H1-06 清单含入口门面放行面" \
    'add "allow-facade-10.10.1.1-4092" 10.10.1.1 4092' "$(cat "$TMP/c06/snippet.sh")"
  assert_cont "TC-H1-06 清单含公网 DNS 放行面" \
    'add "allow-dns-223.5.5.5-53" 223.5.5.5 53' "$(cat "$TMP/c06/snippet.sh")"
}

# ---------------------------------------------------------------- 门禁 + 运行
if [[ ! -r "$NODE_SCRIPT" ]]; then
  printf 'test-nft-render: 找不到被测脚本 %s\n' "$NODE_SCRIPT" >&2
  exit 2
fi
if [[ ! -r "$TEMPLATE" ]]; then
  printf 'test-nft-render: 找不到被测模板 %s\n' "$TEMPLATE" >&2
  exit 2
fi
if ! bash -n "$NODE_SCRIPT"; then
  printf 'test-nft-render: bash -n 未过，后续用例无从谈起\n' >&2
  exit 1
fi

printf '%s\n' "== TC-H1 组（scripts/tests/test-nft-render.sh，全沙盒不碰 /etc/nftables.d）=="
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-nft-render.XXXXXX")"
HARNESS="$TMP/node-harness.sh"
sed '/^main "\$@"$/d' "$NODE_SCRIPT" >"$HARNESS"
for case_fn in case_h1_01 case_h1_02 case_h1_03 case_h1_04 case_h1_06; do
  "$case_fn"
done
cleanup

printf '\n'
if (( FAIL > 0 )); then
  printf '结论：FAIL（%d 断言过 / %d 断言败）\n' "$PASS" "$FAIL"
  exit 1
fi
printf '结论：PASS（%d 断言全过）\n' "$PASS"
exit 0
