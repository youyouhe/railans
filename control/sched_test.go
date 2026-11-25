package main

// sched_test.go — 资源感知调度测试（内部任务单）。
// 静态上限闸（Phase 1）与动态余量地板（Phase 2）全部走垫片/纯函数，不碰真机。

import (
	"context"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// writeTempYaml 落一份 yaml 到临时文件，返回路径（LoadConfig 用例用）。
func writeTempYaml(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

// TC-SCHED-CONFIG：NodeConfig.max_boxes 配置口径——负数报错；缺省 0=不设上限
// （旧形态 config 照常启动）；正数原样读入。
func TestConfigValidateMaxBoxes(t *testing.T) {
	head := `
listen: ":2229"
nodes:
  - name: node1
    address: "192.168.1.11"
    subnet: "10.10.1.0/24"
    gateway: "10.10.1.1"
`

	// 负数 loud fail
	_, err := LoadConfig(writeTempYaml(t, head+"    max_boxes: -1\n"))
	if err == nil || !strings.Contains(err.Error(), "max_boxes must be >= 0") {
		t.Fatalf("err = %v, want max_boxes must be >= 0", err)
	}

	// 旧形态（无 max_boxes 键）照常启动，零值 = 不设节点上限
	cfg, err := LoadConfig(writeTempYaml(t, head))
	if err != nil {
		t.Fatalf("old-form config rejected: %v", err)
	}
	if cfg.Nodes[0].MaxBoxes != 0 {
		t.Fatalf("MaxBoxes = %d, want 0 (no per-node limit)", cfg.Nodes[0].MaxBoxes)
	}

	// 正数读入
	cfg, err = LoadConfig(writeTempYaml(t, head+"    max_boxes: 3\n"))
	if err != nil {
		t.Fatalf("max_boxes 3 rejected: %v", err)
	}
	if cfg.Nodes[0].MaxBoxes != 3 {
		t.Fatalf("MaxBoxes = %d, want 3", cfg.Nodes[0].MaxBoxes)
	}
}

// twoSchedNodes 建两节点控制面（a 在前吃平票优先），boxes 落账由用例自配。
func twoSchedNodes(t *testing.T) *Control {
	t.Helper()
	c := newTestControl(t, stubIncus(t, false))
	a := NodeConfig{Name: "a", Address: "10.0.0.11", Subnet: "10.10.1.0/24", Gateway: "10.10.1.1"}
	b := NodeConfig{Name: "b", Address: "10.0.0.12", Subnet: "10.10.2.0/24", Gateway: "10.10.2.1"}
	c.cfg.Nodes = []NodeConfig{a, b}
	c.cfg.Limits = Limits{BoxTTL: "1h", MaxBoxes: 10, MaxPerKey: 3, MaxPerIPDay: 100}
	c.cfg.PortRange = []int{25100, 25199}
	return c
}

// putBoxOn 落账一只箱在指定节点（fixes_test putBox 的 Node 是硬编码 node1，
// 静态上限闸要按节点落账，自配）。
func putBoxOn(t *testing.T, st *Store, name, fp, node, state string, port int, expires time.Time) {
	t.Helper()
	now := time.Now().UTC()
	if err := st.PutBox(&Box{
		ID: name, Name: name, KeyFP: fp, Node: node,
		VMIP: "10.10.1.10", SSHPort: port, State: state,
		CreatorIP: "127.0.0.1", CreatedAt: now, LastUsed: now, ExpiresAt: expires,
	}); err != nil {
		t.Fatal(err)
	}
}

// TC-SCHED-CAP1：静态上限闸——箱数达 max_boxes 的节点跳过；未达上限照常参选。
func TestPickNodeStaticCap(t *testing.T) {
	c := twoSchedNodes(t)
	far := time.Now().UTC().Add(time.Hour)
	putBoxOn(t, c.store, "box-cap001", "FPCAP1", "a", "running", 25101, far)
	putBoxOn(t, c.store, "box-cap002", "FPCAP2", "a", "stopped", 25102, far)

	// 无上限：b 箱数 0 最少 → b
	c.cfg.Nodes[0].MaxBoxes = 0
	if n := c.pickNode(); n == nil || n.Name != "b" {
		t.Fatalf("pickNode = %+v, want b (least count)", n)
	}

	// a 上限 2、箱数 2（含 stopped——全状态计数）：a 跳过 → b
	c.cfg.Nodes[0].MaxBoxes = 2
	if n := c.pickNode(); n == nil || n.Name != "b" {
		t.Fatalf("pickNode = %+v, want b (a hit static cap)", n)
	}

	// b 上限 1、箱数 1：b 跳过；a 无上限 → a（唯一候选）
	putBoxOn(t, c.store, "box-cap003", "FPCAP3", "b", "creating", 25105, far)
	c.cfg.Nodes[0].MaxBoxes = 0
	c.cfg.Nodes[1].MaxBoxes = 1
	if n := c.pickNode(); n == nil || n.Name != "a" {
		t.Fatalf("pickNode = %+v, want a (b hit static cap)", n)
	}

	// 双双达上限：nil + 两行原因，全状态计数口径（a 的 stopped 也计数）
	c.cfg.Nodes[0].MaxBoxes = 2
	_, reasons := c.pickNodeReasons(context.Background())
	if len(reasons) != 2 {
		t.Fatalf("reasons = %v, want 2 entries (a and b)", reasons)
	}
	if !strings.Contains(reasons[0], "a: static cap 2 reached (boxes 2)") {
		t.Fatalf("reasons[0] = %q, want static cap wording", reasons[0])
	}
}

// TC-SCHED-CAP2：静态上限把全部候选拒掉时，no_node_available 文案并入原因
// （旧裸文案在清单为空场景逐字不变，见 w1_creating_test TC-W1-06）。
func TestNoNodeAvailableMergesStaticCapReasons(t *testing.T) {
	c := twoSchedNodes(t)
	far := time.Now().UTC().Add(time.Hour)
	putBoxOn(t, c.store, "box-cap101", "FPCAPX", "a", "running", 25103, far)
	putBoxOn(t, c.store, "box-cap102", "FPCAPY", "b", "deleting", 25104, far)
	c.cfg.Nodes[0].MaxBoxes = 1
	c.cfg.Nodes[1].MaxBoxes = 1

	_, err := c.ensureBox(context.Background(), &fakeSession{}, "FPCAPNEW", testPubKey(t), false)
	if err == nil {
		t.Fatal("both nodes at static cap must reject new")
	}
	for _, want := range []string{
		"no node available (a: static cap 1 reached (boxes 1); b: static cap 1 reached (boxes 1))",
	} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("err = %q, want it to contain %q", err, want)
		}
	}
	var be *BoxError
	if !errors.As(err, &be) || be.Code != "no_node_available" {
		t.Fatalf("code = %v, want no_node_available", be)
	}
}

// ---- Phase 2：动态余量地板（全部垫片，不碰真机）----

// schedStubIncus 垫片：`query /1.0/resources?target=…`（target URL 参数，
// query 子命令不支持 --target 旗标）与 `list --format json` 回放罐头 JSON，
// 其余子命令空过。query 非 URL 参数形态（如旧 --target 旗标）直接 exit 1 拒收。
func schedStubIncus(t *testing.T, resourcesJSON, listJSON string) *Incus {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "incus-stub")
	rf := filepath.Join(dir, "resources.json")
	lf := filepath.Join(dir, "list.json")
	if err := os.WriteFile(rf, []byte(resourcesJSON), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(lf, []byte(listJSON), 0o644); err != nil {
		t.Fatal(err)
	}
	script := fmt.Sprintf(`#!/bin/sh
d='%s'
case "$1" in
  query) case "$2" in
           /1.0/resources?target=*) cat "$d/resources.json" ;;
           *) echo "stub: query 须用 target URL 参数, got: $2" >&2; exit 1 ;;
         esac ;;
  list)  cat "$d/list.json" ;;
esac
exit 0
`, dir)
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return &Incus{Bin: bin, BaseImage: "dev-base", Profile: "dev"}
}

// schedStubIncusFail 同上，但指定子命令（query/list）exit 1（探测失败回退用例）。
func schedStubIncusFail(t *testing.T, failSub string) *Incus {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "incus-stub")
	script := fmt.Sprintf(`#!/bin/sh
if [ "$1" = "%s" ]; then echo 'stub: probe failure' >&2; exit 1; fi
exit 0
`, failSub)
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return &Incus{Bin: bin, BaseImage: "dev-base", Profile: "dev"}
}

// schedDynControl 双节点控制面 + 每箱 2C/2G 规格（集群画像口径）。
func schedDynControl(t *testing.T, inc *Incus) *Control {
	t.Helper()
	c := twoSchedNodes(t)
	c.incus = inc
	c.cfg.VM = VMConfig{CPUs: 2, Memory: "2GiB", Disk: "20GiB"}
	return c
}

// TC-SCHED-SIZE：尺寸串解析（GiB/裸字节/未知单位不猜）。
func TestSchedParseGiB(t *testing.T) {
	cases := []struct {
		in      string
		want    float64
		wantErr bool
	}{
		{"2GiB", 2, false},
		{"512MiB", 0.5, false},
		{"1073741824", 1, false}, // 裸数字=字节
		{"2gib", 2, false},       // 大小写不敏感
		{"1TiB", 1024, false},
		{" 2GiB ", 2, false},
		{"", 0, true},
		{"2GB", 0, true}, // 未知单位：余量未知，不猜
		{"junk", 0, true},
	}
	for _, tc := range cases {
		got, err := schedParseGiB(tc.in)
		if tc.wantErr {
			if err == nil {
				t.Fatalf("schedParseGiB(%q) = %v, want error", tc.in, got)
			}
			continue
		}
		if err != nil {
			t.Fatalf("schedParseGiB(%q): %v", tc.in, err)
		}
		if math.Abs(got-tc.want) > 1e-9 {
			t.Fatalf("schedParseGiB(%q) = %v, want %v", tc.in, got, tc.want)
		}
	}
}

// TC-SCHED-ALLOC：分配汇总——STOPPED 不计（brief 口径锚）；range 取下界保守；
// 缺键（继承 profile，list JSON 不展开 profile → config 无 limits 键）按回退值
// （vm 规格）累加 fail-open；显式 limits 优先于回退；非空坏串仍 loud。
func TestSchedAllocatedSkipsStopped(t *testing.T) {
	// 组一：无 limits 键 → 用回退值累加。回退 5C/7GiB 故意取与任何显式值无关
	// 的数，误用显式值或忽略回退都一眼可见。
	fbInsts := []schedInstance{
		{"box-a", "Running", "a", "", ""},              // 缺键 → 回退 5C/7GiB
		{"box-b", "Stopped", "a", "", ""},              // STOPPED 不计
		{"box-c", "RUNNING", "a", "2-4", "1073741824"}, // 大写状态 + 显式优先 + 裸字节 + range 下界
	}
	vcpu, mem, err := schedAllocated(fbInsts, 5, 7)
	if err != nil {
		t.Fatalf("schedAllocated: %v", err)
	}
	if vcpu != 7 { // 5（box-a 回退）+ 2（range 下界）；STOPPED 的回退 5 不计
		t.Fatalf("vcpu = %d, want 7", vcpu)
	}
	if math.Abs(mem-8) > 1e-9 { // 7GiB（box-a 回退）+ 1GiB；STOPPED 不计
		t.Fatalf("mem = %v, want 8", mem)
	}

	// 组二：带显式 limits → 显式优先（4C/4GiB ≠ 回退 5C/7GiB，按显式计）
	vcpu, mem, err = schedAllocated([]schedInstance{{"box-d", "Running", "a", "4", "4GiB"}}, 5, 7)
	if err != nil {
		t.Fatalf("schedAllocated: %v", err)
	}
	if vcpu != 4 || math.Abs(mem-4) > 1e-9 {
		t.Fatalf("explicit limits = %dC/%vGiB, want 4C/4GiB (explicit over fallback)", vcpu, mem)
	}

	// 非空但不可解析 → loud（坏数据要响，宁可余量未知，不悄悄低估占用）
	for _, it := range []schedInstance{
		{"box-x", "Running", "a", "junk", ""},
		{"box-y", "Running", "a", "", "junk"},
	} {
		if _, _, err := schedAllocated([]schedInstance{it}, 5, 7); err == nil {
			t.Fatalf("instance %s: unparseable limits must error, not silently undercount", it.Name)
		}
	}
}

// TC-SCHED-ELIG：nodeEligible 表驱动——内存地板/CPU 地板/STOPPED 不计/缺键
// 按回退值计/未知放行。
func TestNodeEligibleTable(t *testing.T) {
	vm := VMConfig{CPUs: 2, Memory: "2GiB"}
	floor1 := schedFloors{MemReserveGiB: 1}
	run2 := func() []schedInstance {
		return []schedInstance{{"x", "Running", "n", "2", "2GiB"}}
	}
	cases := []struct {
		name       string
		stats      *NodeStats
		insts      []schedInstance
		vm         VMConfig
		floors     schedFloors
		wantOK     bool
		wantReason string
	}{
		{
			// 4GiB 总量 - 2GiB running = 2GiB 可用 < 2GiB+1GiB → 内存地板挂
			name: "内存地板不过", stats: &NodeStats{CPUTotal: 2, MemTotalGiB: 4},
			insts: run2(), vm: vm, floors: floor1,
			wantOK: false, wantReason: "memory floor 2GiB+1GiB reserve not met",
		},
		{
			// 8GiB - 2GiB = 6GiB ≥ 3GiB 内存过；4C - 2C = 2C ≥ 2C CPU 过
			name: "内存地板过", stats: &NodeStats{CPUTotal: 4, MemTotalGiB: 8},
			insts: run2(), vm: vm, floors: floor1, wantOK: true,
		},
		{
			// 16GiB 内存宽裕（过内存闸）；4C - 3C 已分配 = 1C < 2C → CPU 地板挂
			name: "CPU 地板不过", stats: &NodeStats{CPUTotal: 4, MemTotalGiB: 16},
			insts: []schedInstance{{"x", "Running", "n", "3", "2GiB"}}, vm: vm, floors: floor1,
			wantOK: false, wantReason: "cpu floor 2C not met (free 1C)",
		},
		{
			// vm.cpus=0（规格未配 CPU）→ 不设 CPU 闸
			name: "CPU 闸随规格缺席", stats: &NodeStats{CPUTotal: 1, MemTotalGiB: 16},
			insts: run2(), vm: VMConfig{Memory: "2GiB"}, floors: floor1, wantOK: true,
		},
		{
			// STOPPED 不计（口径反证：同一总量若计入 2GiB，内存地板必挂）
			name: "STOPPED 不计", stats: &NodeStats{CPUTotal: 2, MemTotalGiB: 4},
			insts: []schedInstance{{"x", "Stopped", "n", "2", "2GiB"}}, vm: vm, floors: floor1,
			wantOK: true,
		},
		{
			// 预留 0：2GiB 可用 = 2GiB 需求贴线 → 过（CPU 给足避开 CPU 闸）
			name: "预留 0 贴线过", stats: &NodeStats{CPUTotal: 4, MemTotalGiB: 4},
			insts: run2(), vm: vm, floors: schedFloors{}, wantOK: true,
		},
		{
			name: "stats 缺失=未知放行", stats: nil,
			insts: run2(), vm: vm, floors: floor1, wantOK: true,
		},
		{
			// 缺键 limits（继承 profile）按 vm 规格回退计：4GiB - 2GiB（回退）
			// = 2GiB < 2GiB+1GiB → 内存地板挂（真实实例形态的闸层回归锚）
			name: "缺键 limits 按回退值计", stats: &NodeStats{CPUTotal: 2, MemTotalGiB: 4},
			insts: []schedInstance{{"x", "Running", "n", "", ""}}, vm: vm, floors: floor1,
			wantOK: false, wantReason: "memory floor 2GiB+1GiB reserve not met",
		},
		{
			name: "实例 limits 不可解析=未知放行", stats: &NodeStats{CPUTotal: 2, MemTotalGiB: 4},
			insts: []schedInstance{{"x", "Running", "n", "2", "junk"}}, vm: vm, floors: floor1,
			wantOK: true,
		},
		{
			name: "vm 规格不可解析=未知放行", stats: &NodeStats{CPUTotal: 2, MemTotalGiB: 4},
			insts: run2(), vm: VMConfig{CPUs: 2, Memory: "junk"}, floors: floor1,
			wantOK: true,
		},
	}
	for _, tc := range cases {
		ok, why := nodeEligible(tc.stats, tc.insts, tc.vm, tc.floors)
		if ok != tc.wantOK {
			t.Fatalf("%s: ok = %v (why=%q), want %v", tc.name, ok, why, tc.wantOK)
		}
		if tc.wantReason != "" && !strings.Contains(why, tc.wantReason) {
			t.Fatalf("%s: why = %q, want it to contain %q", tc.name, why, tc.wantReason)
		}
		if tc.wantOK && why != "" {
			t.Fatalf("%s: ok with reason %q, want empty", tc.name, why)
		}
	}
}

// TC-SCHED-FETCH：fetchNodeStats 垫片组装——总量/分配/STOPPED 剔除逐字段核对；
// 缺键 limits（继承 profile，list JSON 不展开 profile → config 无键，真实实例
// 形态）按 vm 规格回退，显式 limits 优先于回退；探测失败/垃圾输出/vm 规格
// 坏串 = error（调用方回退静态闸）。
func TestFetchNodeStatsStub(t *testing.T) {
	res := `{"cpu":{"total":2},"memory":{"total":4294967296}}`
	// 组一：无 limits 键 → 用回退值累加（罐头走真实 JSON 形态，缺键经
	// schedListInstances 落成空串再回退，journald limits.cpu: missing 事故回归锚）
	list := `[
		{"name":"box-a","status":"Running","location":"a","config":{"security.privileged":"0"}},
		{"name":"box-b","status":"Stopped","location":"a","config":{"limits.cpu":"2","limits.memory":"2GiB"}}
	]`
	inc := schedStubIncus(t, res, list)
	vm := VMConfig{CPUs: 2, Memory: "2GiB"}
	insts, err := schedListInstances(context.Background(), inc)
	if err != nil {
		t.Fatalf("schedListInstances: %v", err)
	}
	if insts[0].LimitsCPU != "" || insts[0].LimitsMemory != "" {
		t.Fatalf("missing limits keys must surface as empty strings, got %+v", insts[0])
	}
	stats, err := fetchNodeStats(context.Background(), inc, "a", insts, vm)
	if err != nil {
		t.Fatalf("fetchNodeStats: %v", err)
	}
	if stats.CPUTotal != 2 || math.Abs(stats.MemTotalGiB-4) > 1e-9 {
		t.Fatalf("totals = %+v, want cpu 2 mem 4GiB", stats)
	}
	if math.Abs(stats.MemAvailableGiB-2) > 1e-9 { // 4 - 2（box-a 回退 2GiB；STOPPED 不计）
		t.Fatalf("mem_avail = %v, want 2", stats.MemAvailableGiB)
	}
	if stats.VCPUAllocated != 2 { // box-a 回退 2C；STOPPED 不计
		t.Fatalf("vcpu_allocated = %d, want 2", stats.VCPUAllocated)
	}

	// 组二：带显式 limits → 显式优先（4C/4GiB ≠ 回退 2C/2GiB，按显式计）
	list2 := `[{"name":"box-c","status":"Running","location":"a","config":{"limits.cpu":"4","limits.memory":"4GiB"}}]`
	incX := schedStubIncus(t, res, list2)
	instsX, err := schedListInstances(context.Background(), incX)
	if err != nil {
		t.Fatalf("schedListInstances explicit: %v", err)
	}
	statsX, err := fetchNodeStats(context.Background(), incX, "a", instsX, vm)
	if err != nil {
		t.Fatalf("fetchNodeStats explicit: %v", err)
	}
	if statsX.VCPUAllocated != 4 || math.Abs(statsX.MemAvailableGiB) > 1e-9 {
		t.Fatalf("explicit = vcpu %d avail %v, want vcpu 4 avail 0", statsX.VCPUAllocated, statsX.MemAvailableGiB)
	}

	// 回退值本身不可解析（vm.memory 坏串）→ error（余量未知回退静态闸）
	if _, err := fetchNodeStats(context.Background(), inc, "a", insts, VMConfig{CPUs: 2, Memory: "junk"}); err == nil {
		t.Fatal("bad vm.memory fallback must error")
	}

	// query 垃圾输出 → 解析 error
	inc2 := schedStubIncus(t, "not-json", list)
	if _, err := fetchNodeStats(context.Background(), inc2, "a", insts, vm); err == nil {
		t.Fatal("garbage resources output must error")
	}
	// query exit 1 → error
	inc3 := schedStubIncusFail(t, "query")
	if _, err := fetchNodeStats(context.Background(), inc3, "a", insts, vm); err == nil {
		t.Fatal("failed query must error")
	}
	// list exit 1 → error
	inc4 := schedStubIncusFail(t, "list")
	if _, err := schedListInstances(context.Background(), inc4); err == nil {
		t.Fatal("failed list must error")
	}
}

// TC-SCHED-DYN1：探测失败回退——query/list 挂掉时该节点余量未知，
// 仅静态闸放行（不得因探测失败全局拒建）。
func TestPickNodeDynProbeFallback(t *testing.T) {
	c := schedDynControl(t, schedStubIncusFail(t, "query"))
	n := c.pickNode()
	if n == nil {
		t.Fatal("probe failure must not globally refuse; want a node picked")
	}
	if n.Name != "a" {
		t.Fatalf("pickNode = %v, want a (tie-break)", n.Name)
	}
	// 探针口径：余量未知 = mem/vcpu 为 nil、eligible 按静态闸
	p := c.schedProbe(context.Background(), c.store.CountByNode())["a"]
	if p.Dyn.MemAvailGiB != nil || p.Dyn.VCPUFree != nil || !p.Dyn.Eligible {
		t.Fatalf("probe = %+v, want nil mem/vcpu + eligible", p.Dyn)
	}
	// list 也挂：同样回退
	c2 := schedDynControl(t, schedStubIncusFail(t, "list"))
	if n := c2.pickNode(); n == nil || n.Name != "a" {
		t.Fatalf("pickNode with failed list = %+v, want a", n)
	}
}

// TC-SCHED-DYN2：动态地板全拒——no_node_available 文案并入内存地板原因
// （brief 锚格式 node3: memory floor 2GiB+1GiB reserve not met）。
func TestNoNodeAvailableMergesDynFloorReasons(t *testing.T) {
	res := `{"cpu":{"total":2},"memory":{"total":4294967296}}`
	list := `[
		{"name":"box-a","status":"Running","location":"a","config":{"limits.cpu":"2","limits.memory":"2GiB"}},
		{"name":"box-b","status":"Running","location":"b","config":{"limits.cpu":"2","limits.memory":"2GiB"}}
	]`
	c := schedDynControl(t, schedStubIncus(t, res, list))
	_, err := c.ensureBox(context.Background(), &fakeSession{}, "FPDYN1", testPubKey(t), false)
	if err == nil {
		t.Fatal("both nodes below memory floor must reject new")
	}
	for _, want := range []string{
		"no node available (a: memory floor 2GiB+1GiB reserve not met",
		"b: memory floor 2GiB+1GiB reserve not met",
	} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("err = %q, want it to contain %q", err, want)
		}
	}
	var be *BoxError
	if !errors.As(err, &be) || be.Code != "no_node_available" {
		t.Fatalf("code = %v, want no_node_available", be)
	}
}

// TC-SCHED-DYN3：静态+动态叠加——静态闸拒 a（不探测）、动态地板拒 b，
// 文案只收 b 的动态原因；动态地板放行的节点正常落箱。
func TestPickNodeStaticPlusDynStacking(t *testing.T) {
	res := `{"cpu":{"total":2},"memory":{"total":4294967296}}`
	list := `[
		{"name":"box-b1","status":"Running","location":"b","config":{"limits.cpu":"2","limits.memory":"2GiB"}}
	]`
	c := schedDynControl(t, schedStubIncus(t, res, list))
	far := time.Now().UTC().Add(time.Hour)
	putBoxOn(t, c.store, "box-s001", "FPS1", "a", "running", 25106, far)
	putBoxOn(t, c.store, "box-s002", "FPS2", "a", "running", 25107, far)
	c.cfg.Nodes[0].MaxBoxes = 2 // a 达静态上限

	// 双闸叠加：a 静态拒（不探测），b 动态拒——原因两行都在（新闸全收）
	_, reasons := c.pickNodeReasons(context.Background())
	if len(reasons) != 2 {
		t.Fatalf("reasons = %v, want 2 (a static + b dyn)", reasons)
	}
	if !strings.Contains(reasons[0], "a: static cap 2 reached (boxes 2)") {
		t.Fatalf("reasons[0] = %q, want a static cap", reasons[0])
	}
	if !strings.Contains(reasons[1], "b: memory floor 2GiB+1GiB reserve not met") {
		t.Fatalf("reasons[1] = %q, want b memory floor", reasons[1])
	}
	_, err := c.ensureBox(context.Background(), &fakeSession{}, "FPDYN2", testPubKey(t), false)
	if err == nil || !strings.Contains(err.Error(), "no node available (a: static cap 2 reached (boxes 2); b: memory floor") {
		t.Fatalf("err = %v, want merged dual-gate reasons", err)
	}
}

// TC-SCHED-DYN4：动态地板放行——余量充足的节点照常选中（双闸不误伤）。
func TestPickNodeDynFloorPass(t *testing.T) {
	res := `{"cpu":{"total":4},"memory":{"total":17179869184}}` // 4C/16GiB
	list := `[
		{"name":"box-a1","status":"Running","location":"a","config":{"limits.cpu":"2","limits.memory":"2GiB"}}
	]`
	c := schedDynControl(t, schedStubIncus(t, res, list))
	far := time.Now().UTC().Add(time.Hour)
	putBoxOn(t, c.store, "box-p001", "FPP1", "a", "running", 25108, far)
	// b 空载：箱数 0 最少 + 余量 16GiB/4C 全过地板 → b
	if n := c.pickNode(); n == nil || n.Name != "b" {
		t.Fatalf("pickNode = %+v, want b", n)
	}
	p := c.schedProbe(context.Background(), c.store.CountByNode())["a"]
	if p.Dyn.MemAvailGiB == nil || math.Abs(*p.Dyn.MemAvailGiB-14) > 1e-9 {
		t.Fatalf("a mem_avail = %v, want 14", *p.Dyn.MemAvailGiB)
	}
	if p.Dyn.VCPUFree == nil || *p.Dyn.VCPUFree != 2 {
		t.Fatalf("a vcpu_free = %v, want 2", p.Dyn.VCPUFree)
	}
}

// TC-SCHED-CAPJSON：capacityJSON 动态口径渲染——cap（null=未设）/mem_avail_gib
// /vcpu_free（null=余量未知）/eligible 逐字段；探测失败节点 eligible 仅静态口径。
func TestCapacityJSONDynFields(t *testing.T) {
	nodes := []NodeConfig{
		{Name: "full", MaxBoxes: 3},
		{Name: "free"}, // 未设上限 → cap null
	}
	dyn := map[string]capNodeDyn{
		"full": {Eligible: false}, // 静态拒：无 mem/vcpu 数据
		"free": {MemAvailGiB: fp64(14.5), VCPUFree: ip(2), Eligible: true},
	}
	out := capacityJSON(nil, 12, map[string]int{"full": 3, "free": 1}, nodes, 22000, 22999, dyn)
	s := string(out)
	for _, want := range []string{
		`"node": "full"`,
		`"boxes": 3`,
		`"cap": 3`,
		`"mem_avail_gib": null`, // full 行：静态拒无探测数据
		`"vcpu_free": null`,
		`"eligible": false`,
		`"node": "free"`,
		`"cap": null`,
		`"mem_avail_gib": 14.5`,
		`"vcpu_free": 2`,
		`"eligible": true`,
	} {
		if !strings.Contains(s, want) {
			t.Fatalf("capacityJSON = %s, want it to contain %s", s, want)
		}
	}
	// dyn 缺席（旧调用形态/探针未跑）→ 三字段 null/false 兜底渲染
	out2 := capacityJSON(nil, 12, map[string]int{}, nodes, 22000, 22999, nil)
	s2 := string(out2)
	if !strings.Contains(s2, `"mem_avail_gib": null`) || !strings.Contains(s2, `"eligible": false`) {
		t.Fatalf("capacityJSON without dyn = %s, want null/false fallback", s2)
	}
}

func fp64(v float64) *float64 { return &v }
func ip(v int) *int           { return &v }
