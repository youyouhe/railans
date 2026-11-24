#!/usr/bin/env bash
# newbox — railans 客户端封装
#
#   newbox                 创建（或复用）自己的 box，并直接 SSH 进去
#   newbox new [--json]    只创建，打印信息
#   newbox ls              列出自己的 box
#   newbox ssh [box]       进入已有 box
#   newbox rm <box>        删除
#   newbox stop|start <box>
#   newbox snapshot <box>
#   newbox share <box>
#   newbox info <box>
#   newbox enroll <code> [label]
#
# 环境变量：
#   RAILANS_HOST   控制面地址（默认 new.box.lan）
#   RAILANS_PORT   控制面端口（默认 22；测试环境 2229）
#   RAILANS_USER   控制面用户名（默认 root，仅用于满足 SSH 语法，服务端忽略）
set -euo pipefail

CONTROL_HOST="${RAILANS_HOST:-new.box.lan}"
CONTROL_PORT="${RAILANS_PORT:-22}"
CONTROL_USER="${RAILANS_USER:-root}"
SSH=(ssh -o LogLevel=ERROR -p "$CONTROL_PORT" "${CONTROL_USER}@${CONTROL_HOST}")

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

json_field() {
  # json_field <json> <field>
  printf '%s' "$1" | sed -n "s/.*\"$2\": *\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" | head -n1
}

connect() {
  local box="${1:-}"
  local payload
  if [[ -z "${box}" ]]; then
    payload="$("${SSH[@]}" new --json)"
  else
    payload="$("${SSH[@]}" info "${box}" 2>/dev/null || true)"
    if [[ -z "${payload}" ]]; then
      # info 输出的是原始 box 记录，字段同名，直接复用
      echo "box ${box} not found" >&2
      exit 1
    fi
  fi
  local port
  port="$(json_field "${payload}" ssh_port)"
  if [[ -z "${port}" ]]; then
    echo "无法从控制面响应中解析 ssh_port：" >&2
    echo "${payload}" >&2
    exit 1
  fi
  exec ssh -p "${port}" -o LogLevel=ERROR -o StrictHostKeyChecking=accept-new dev@"${CONTROL_HOST}"
}

cmd="${1:-connect}"
shift || true

case "${cmd}" in
  connect)
    if ! command -v ssh >/dev/null 2>&1; then
      echo "需要 OpenSSH 客户端（ssh）" >&2
      exit 1
    fi
    connect "${1:-}"
    ;;
  ssh)
    connect "${1:-}"
    ;;
  new)
    exec "${SSH[@]}" new "$@"
    ;;
  ls|list|rm|delete|stop|start|snapshot|share|info)
    exec "${SSH[@]}" "${cmd}" "$@"
    ;;
  enroll)
    exec "${SSH[@]}" enroll "$@"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    # 其它情况当作 box 名，等价于 newbox ssh <name>
    connect "${cmd}"
    ;;
esac

