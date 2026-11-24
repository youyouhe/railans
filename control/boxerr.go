package main

import (
	"encoding/json"
	"errors"
)

// BoxError 是 `new`/`wait` 错误路径的结构化信封载体
// (内部方案文档 §1.2-§1.4，内部正本，未随公开版发布)。
// 关键设计:Error() 返回旧文本(Msg)——非 json 路径(handle 层 `error: %v`)
// 与既有文本客户端逐字零感知(TC-W1-02 硬锚);机器判断只认 --json 信封里的 code。
//
// 错误码枚举(方案 §1.3 表):creating_in_progress / stuck_deleting / start_failed /
// wait_ready_failed / limit_max_boxes / limit_per_key / limit_per_ip_day /
// no_vm_node_available / no_node_available / allocation_failed / name_collision /
// launch_failed / key_push_failed / asset_push_failed / proxy_failed /
// state_write_failed / source_not_allowed / wait_timeout / wait_target_gone /
// wait_not_owner / internal。
// asset_push_failed（H2，railans-kit#7）:box_assets 按箱注入失败，retryable=true；
// ensureBox 走 cleanup（删 VM + 删记录），无半交付箱。
// 其中 internal 是兜底枚举位:本波 §1.3 表已覆盖 ensureBox 全部错误点,无未覆盖落点;
// 信封总有 code 由构造器保证(渲染未命中的错误走旧文本路径,见 renderNewErrorJSON)。
type BoxError struct {
	Code       string // 错误码,机器判断只认它
	Msg        string // 旧文本,Error() 逐字返回
	Box        string // 有 box 语境的码才携带(creating/stuck/collision),缺省省略
	Retryable  bool   // true = 调用方原样重试同一调用有意义
	RetryAfter int    // 建议重试间隔秒数,仅 creating_in_progress 携带(固定 5);0 = 省略
}

// Error 返回旧文本(逐字兼容锚):非 json 路径与既有 strings.Contains 风格测试零漂移。
func (e *BoxError) Error() string { return e.Msg }

// newBoxError 构造带错误码的错误。box 传 "" 表示不携带 box 键;
// retryAfter 传 0 表示不携带 retry_after_seconds 键。
func newBoxError(code, msg string, box string, retryable bool, retryAfter int) *BoxError {
	return &BoxError{Code: code, Msg: msg, Box: box, Retryable: retryable, RetryAfter: retryAfter}
}

// wrapBoxError 把透传的底层错误(store/incus/proxy)包进结构化码,
// 文本保持底层错误逐字不变(旧路径兼容)。
func wrapBoxError(code string, err error, retryable bool) *BoxError {
	return &BoxError{Code: code, Msg: err.Error(), Retryable: retryable}
}

// renderNewErrorJSON 纯函数:errors.As 提取 *BoxError,命中则渲染 --json 错误信封
// (MarshalIndent,与成功路径 boxView 风格一致;顶层 error 键与 boxView 天然可区分)
// 与 true;未命中返回 false,调用方走旧文本路径(方案 §1.4-3,TC-W1-09 选定形态)。
func renderNewErrorJSON(err error) (string, bool) {
	var be *BoxError
	if !errors.As(err, &be) {
		return "", false
	}
	body := struct {
		Code              string `json:"code"`
		Message           string `json:"message"`
		Box               string `json:"box,omitempty"`
		Retryable         bool   `json:"retryable"`
		RetryAfterSeconds int    `json:"retry_after_seconds,omitempty"`
	}{be.Code, be.Msg, be.Box, be.Retryable, be.RetryAfter}
	out, _ := json.MarshalIndent(struct {
		Error interface{} `json:"error"`
	}{body}, "", "  ")
	return string(out), true
}
