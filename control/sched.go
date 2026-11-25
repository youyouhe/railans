package main

// sched.go — 资源感知调度：动态余量地板的数据组装与纯函数闸（内部任务单 Phase 2）。
//
// 口径锚（brief 2026-11-25，站长立项）：
//   - 总量：incus query /1.0/resources?target=<member>（REST
//     GET /1.0/resources，节点经 target URL 参数指定）给 CPU/内存总量；
//   - 已分配：incus list --format json 的 location+limits；注意 instance config
//     不展开 profile（继承 profile 的实例 limits.cpu/limits.memory 缺键），缺键
//     按 vm 规格回退累加（schedAllocated），非空坏串仍报错；STOPPED 实例不占
//     CPU/内存，不计入分配；
//   - 地板：mem_available ≥ vm.memory + 预留（schedMemReserveGiB，常量 1GiB）；
//     cpu_total - vcpu_allocated ≥ vm.cpus；
//   - 探测失败/超时（5s）= 该节点余量未知 → 回退仅静态闸并记 WARN
//     （不得因探测失败全局拒建）。
//
// 全部 incus 调用集中在 schedListInstances/fetchNodeStats 两个垫片友好入口；
// nodeEligible/schedAllocated 是纯函数（sched_test.go 表驱动）。

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"
)

// schedMemReserveGiB 动态地板的宿主内存预留（brief 定数）：给 incus 守护与
// 系统留 1GiB，余量按「箱规格 + 预留」卡线。
const schedMemReserveGiB = 1.0

// schedProbeTimeout 单条 incus 探测（query/list）超时；超时 = 余量未知，走回退。
const schedProbeTimeout = 5 * time.Second

// schedDefaultFloors 生产地板参数（floors 参数化，测试可调）。
var schedDefaultFloors = schedFloors{MemReserveGiB: schedMemReserveGiB}

// NodeStats 节点实时余量画像。MemAvailableGiB/VCPUAllocated 供 capacity 报告
// 直读；nodeEligible 的分配从实例清单现场推导（同一 schedAllocated 源，口径
// 不漂移——STOPPED 不计在纯函数层可测）。
type NodeStats struct {
	CPUTotal        int     `json:"cpu_total"`
	MemTotalGiB     float64 `json:"mem_total_gib"`
	MemAvailableGiB float64 `json:"mem_avail_gib"`
	VCPUAllocated   int     `json:"vcpu_allocated"`
}

// schedFloors 动态地板参数（GiB）。
type schedFloors struct {
	MemReserveGiB float64
}

// schedInstance 调度口径的实例快照（incus list 展开配置，Status 为 incus 原词，
// STOPPED 判定大小写不敏感）。
type schedInstance struct {
	Name         string
	Status       string
	Location     string
	LimitsCPU    string
	LimitsMemory string
}

// schedParseGiB 解析 incus 尺寸串为 GiB："2GiB"/"512MiB"/"1073741824"（裸数字
// = 字节）。二进制单位 KiB..PiB 大小写不敏感；未知单位/空串报错（调用方按
// 「余量未知」回退，不猜）。
func schedParseGiB(s string) (float64, error) {
	t := strings.ToLower(strings.TrimSpace(s))
	if t == "" {
		return 0, fmt.Errorf("empty size")
	}
	mult := 1.0 / (1 << 30) // 裸数字按字节计（bytes → GiB）
	// 二进制单位倍率 = 2^shift / 2^30（kib 2^-20 … pib 2^20；gib=1）
	suffixes := []struct {
		suf  string
		mult float64
	}{
		{"pib", 1 << 20}, {"tib", 1024}, {"gib", 1}, {"mib", 1.0 / 1024}, {"kib", 1.0 / (1 << 20)},
	}
	for _, u := range suffixes {
		if strings.HasSuffix(t, u.suf) {
			mult = u.mult
			t = strings.TrimSuffix(t, u.suf)
			break
		}
	}
	v, err := strconv.ParseFloat(strings.TrimSpace(t), 64)
	if err != nil {
		return 0, fmt.Errorf("size %q: %w", s, err)
	}
	return v * mult, nil
}

// gibLabel GiB 数值 → 人读标签（整数无小数点，如 1GiB / 0.5GiB）。
func gibLabel(g float64) string {
	if g == math.Trunc(g) {
		return fmt.Sprintf("%dGiB", int64(g))
	}
	return fmt.Sprintf("%gGiB", g)
}

// schedFirstInt 取串中首个整数。limits.cpu 的 "2"/"2-4"/"1,3" 形态取下界
// （保守：按最少占用计）。
func schedFirstInt(s string) (int, error) {
	t := strings.TrimSpace(s)
	if t == "" {
		return 0, fmt.Errorf("missing")
	}
	i := 0
	for i < len(t) && (t[i] < '0' || t[i] > '9') {
		i++
	}
	if i == len(t) {
		return 0, fmt.Errorf("no digit in %q", s)
	}
	j := i
	for j < len(t) && t[j] >= '0' && t[j] <= '9' {
		j++
	}
	return strconv.Atoi(t[i:j])
}

// schedAllocated 汇总非 STOPPED 实例的 limits（STOPPED 不占 CPU/内存，不计入
// ——brief 口径锚）。fbVCPU/fbMemGiB 是缺键回退值（vm 规格：继承 profile 的实例
// 在 list JSON 里 limits.cpu/limits.memory 缺键，config 不展开 profile，按本
// 控制面落箱的标准规格计）：空串/缺键 → 用回退值累加，fail-open 不响；非空但
// 不可解析 → 整体报错：坏数据要响，宁可余量未知回退静态闸，也不悄悄低估占用。
func schedAllocated(insts []schedInstance, fbVCPU int, fbMemGiB float64) (int, float64, error) {
	vcpu := 0
	mem := 0.0
	for _, it := range insts {
		if strings.EqualFold(strings.TrimSpace(it.Status), "stopped") {
			continue
		}
		c := fbVCPU
		if strings.TrimSpace(it.LimitsCPU) != "" {
			v, err := schedFirstInt(it.LimitsCPU)
			if err != nil {
				return 0, 0, fmt.Errorf("instance %s limits.cpu: %w", it.Name, err)
			}
			c = v
		}
		g := fbMemGiB
		if strings.TrimSpace(it.LimitsMemory) != "" {
			v, err := schedParseGiB(it.LimitsMemory)
			if err != nil {
				return 0, 0, fmt.Errorf("instance %s limits.memory: %w", it.Name, err)
			}
			g = v
		}
		vcpu += c
		mem += g
	}
	return vcpu, mem, nil
}

// nodeEligible 纯函数：单节点动态地板闸（可测核心）。
// stats 只取总量（CPUTotal/MemTotalGiB）；分配从 insts 现场推导（STOPPED 不计）。
// 返回（是否可落箱, 拒绝原因）。判定不了（vm 规格/实例 limits 不可解析）=
// 可落箱：与探测失败同语义，余量未知不拒建。
func nodeEligible(stats *NodeStats, insts []schedInstance, vm VMConfig, floors schedFloors) (bool, string) {
	if stats == nil {
		return true, ""
	}
	// vm 规格既当新箱需求，也当缺键实例的 limits 回退值（同一口径，见
	// schedAllocated）；不可解析 = 需求与回退都未知 → 放行（与探测失败同语义）。
	memNeed, err := schedParseGiB(vm.Memory)
	if err != nil {
		return true, ""
	}
	vcpuAlloc, memUsed, err := schedAllocated(insts, vm.CPUs, memNeed)
	if err != nil {
		return true, ""
	}
	memAvail := stats.MemTotalGiB - memUsed
	if memAvail < memNeed+floors.MemReserveGiB {
		return false, fmt.Sprintf("memory floor %s+%s reserve not met (avail %s)",
			vm.Memory, gibLabel(floors.MemReserveGiB), gibLabel(memAvail))
	}
	cpuFree := stats.CPUTotal - vcpuAlloc
	if vm.CPUs > 0 && cpuFree < vm.CPUs {
		return false, fmt.Sprintf("cpu floor %dC not met (free %dC)", vm.CPUs, cpuFree)
	}
	return true, ""
}

// schedListInstances 读集群实例清单（incus list --format json）。instance
// config 不展开 profile：继承 profile 的实例 limits.cpu/limits.memory 缺键
// （空串），由 schedAllocated 按 vm 规格回退。与 incus.List（对账字段）不共用，
// 且 incus.go 本波禁碰。
func schedListInstances(ctx context.Context, inc *Incus) ([]schedInstance, error) {
	out, err := inc.run(ctx, schedProbeTimeout, "list", "--format", "json")
	if err != nil {
		return nil, err
	}
	var raw []struct {
		Name     string            `json:"name"`
		Status   string            `json:"status"`
		Location string            `json:"location"`
		Config   map[string]string `json:"config"`
	}
	if err := json.Unmarshal([]byte(out), &raw); err != nil {
		return nil, fmt.Errorf("parse incus list: %w", err)
	}
	insts := make([]schedInstance, 0, len(raw))
	for _, r := range raw {
		insts = append(insts, schedInstance{
			Name:         r.Name,
			Status:       r.Status,
			Location:     r.Location,
			LimitsCPU:    r.Config["limits.cpu"],
			LimitsMemory: r.Config["limits.memory"],
		})
	}
	return insts, nil
}

// fetchNodeStats 组装单节点余量画像：总量经 incus query 的 target URL 参数
// （/1.0/resources?target=<member>；query 子命令不支持 --target 旗标），
// 分配经调用方传入的该节点实例清单
// （schedListInstances 全集群拉一次后按 location 分桶，别每节点重拉）。
// vm 提供缺键 limits 的回退规格；回退值本身不可解析（vm.memory 坏串）= 余量
// 未知，报错由调用方回退静态闸。
func fetchNodeStats(ctx context.Context, inc *Incus, node string, insts []schedInstance, vm VMConfig) (*NodeStats, error) {
	out, err := inc.run(ctx, schedProbeTimeout, "query", "/1.0/resources?target="+node)
	if err != nil {
		return nil, err
	}
	var res struct {
		CPU struct {
			Total int `json:"total"`
		} `json:"cpu"`
		Memory struct {
			Total int64 `json:"total"`
		} `json:"memory"`
	}
	if err := json.Unmarshal([]byte(out), &res); err != nil {
		return nil, fmt.Errorf("parse resources of %s: %w", node, err)
	}
	fbMemGiB, err := schedParseGiB(vm.Memory)
	if err != nil {
		return nil, fmt.Errorf("vm.memory fallback: %w", err)
	}
	vcpuAlloc, memUsed, err := schedAllocated(insts, vm.CPUs, fbMemGiB)
	if err != nil {
		return nil, err
	}
	memTotalGiB := float64(res.Memory.Total) / (1 << 30)
	return &NodeStats{
		CPUTotal:        res.CPU.Total,
		MemTotalGiB:     memTotalGiB,
		MemAvailableGiB: memTotalGiB - memUsed,
		VCPUAllocated:   vcpuAlloc,
	}, nil
}
