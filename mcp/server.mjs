#!/usr/bin/env node
// railans-mcp — railans 集群 CLI 的 MCP 包装器
// 传输：stdio；每个工具经 ssh 调用控制面命令（<user>@<host> -p <port>；服务端只认公钥，用户名随意）
// 安全：读工具（list/info/capacity）readOnlyHint；rm/stop destructiveHint；
//       实际鉴权由控制面承担（key + enroll + per-key 所有权）
import { execFile } from 'node:child_process'
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { z } from 'zod'

const HOST = process.env.RAILANS_HOST ?? '127.0.0.1'
const ENROLL_CODE = process.env.RAILANS_ENROLL_CODE ?? ''
const PORT = process.env.RAILANS_PORT ?? '2229'
const USER = process.env.RAILANS_USER ?? 'ops'
const SSH = ['ssh', '-p', PORT, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new', `${USER}@${HOST}`]

function ssh(args, timeoutMs = 30_000) {
  return new Promise((resolve) => {
    execFile(SSH[0], [...SSH.slice(1), ...args], { timeout: timeoutMs, maxBuffer: 4 * 1024 * 1024 }, (err, stdout, stderr) => {
      resolve({ err, stdout: stdout ?? '', stderr: stderr ?? '', code: err?.code ?? 0 })
    })
  })
}

function sshLong(args) {
  return ssh(args, 360_000) // create/start 最长 6 分钟
}

function text(str, isError = false) {
  return { content: [{ type: 'text', text: str }], isError }
}

function fail(r, what) {
  return text(`ssh ${what} 失败 (exit ${r.code}):\n${r.stderr || r.stdout}`, true)
}

const BOX = { box: { type: 'string', description: 'box 名，如 box-8a816c' } }

const server = new McpServer(
  { name: 'railans-mcp', version: '0.1.0' },
  { instructions: 'railans VM 集群的 CLI 包装。创建用 create（阻塞最长 360s；首启可能更久，客户端超时建议 ≥360s）；预览地址 box-<hash>.<预览域名>（示例 boxes.example.org）；删除等破坏性操作已标 destructiveHint。' },
)

server.registerTool(
  'create',
  {
    description: '创建（或复用同 key 已有的）开发 VM。阻塞约 90–120 秒；同 key 幂等（已持有则返回现有 box）。',
    inputSchema: {},
  },
  async () => {
    const r = await sshLong(['new', '--json'])
    if (r.err) return fail(r, 'new')
    return text(r.stdout.trim())
  },
)

server.registerTool(
  'list',
  {
    description: '列出当前身份的全部 box（name/node/ip/port/state/expires）。',
    inputSchema: {},
    annotations: { readOnlyHint: true },
  },
  async () => {
    const r = await ssh(['ls', '--json'])
    if (r.err) return fail(r, 'ls')
    try { return text(JSON.stringify(JSON.parse(r.stdout), null, 2)) }
    catch { return text(r.stdout) }
  },
)

server.registerTool(
  'capacity',
  {
    description: '集群余量与分布（boxes_total/max/available、各节点箱数、端口池范围）。',
    inputSchema: {},
    annotations: { readOnlyHint: true },
  },
  async () => {
    const r = await ssh(['capacity'])
    if (r.err) return fail(r, 'capacity')
    return text(r.stdout.trim())
  },
)

server.registerTool(
  'info',
  {
    description: '查询单台 box 的完整记录（name/node/ip/port/state/expires/key_fp）。',
    inputSchema: { box: z.string().describe('box 名，如 box-8a816c') },
    annotations: { readOnlyHint: true },
  },
  async ({ box }) => {
    const r = await ssh(['info', box])
    if (r.err) return fail(r, 'info')
    try { return text(JSON.stringify(JSON.parse(r.stdout), null, 2)) }
    catch { return text(r.stdout) }
  },
)

server.registerTool(
  'stop',
  {
    description: '停止 box（磁盘保留，数据不丢）。',
    inputSchema: { box: z.string().describe('box 名') },
    annotations: { destructiveHint: true },
  },
  async ({ box }) => {
    const r = await ssh(['stop', box])
    if (r.err) return fail(r, 'stop')
    return text(r.stdout.trim())
  },
)

server.registerTool(
  'start',
  {
    description: '启动已停止的 box（约 20–60 秒）。',
    inputSchema: { box: z.string().describe('box 名') },
  },
  async ({ box }) => {
    const r = await sshLong(['start', box])
    if (r.err) return fail(r, 'start')
    return text(r.stdout.trim())
  },
)

server.registerTool(
  'snapshot',
  {
    description: '为 box 创建存储快照（即时，按 box 名+时间戳命名）。',
    inputSchema: { box: z.string().describe('box 名') },
  },
  async ({ box }) => {
    const r = await ssh(['snapshot', box])
    if (r.err) return fail(r, 'snapshot')
    return text(r.stdout.trim())
  },
)

server.registerTool(
  'share',
  {
    description: '将 box 预览设为可分享（解除来源 IP 门禁，URL 可交给他人）。',
    inputSchema: { box: z.string().describe('box 名') },
  },
  async ({ box }) => {
    const r = await ssh(['share', box])
    if (r.err) return fail(r, 'share')
    return text(r.stdout.trim())
  },
)

server.registerTool(
  'enroll',
  {
    description: '注册一把新公钥为新身份（新设备/新 agent 准入）。code 由服务端环境变量提供，不出现在调用参数里。',
    inputSchema: {
      pubkey: z.string().describe('完整公钥行：ssh-ed25519 AAAA... user@host'),
      label: z.string().describe('身份标签，如 newlaptop'),
    },
    annotations: { destructiveHint: true },
  },
  async ({ pubkey, label }) => {
    if (!ENROLL_CODE) return text('错误：服务端未配置 RAILANS_ENROLL_CODE', true)
    // ssh 客户端把 argv 以空格拼成远端命令串，服务端按 shlex 拆词：多词公钥行
    // 不引号会被拆散（rest[0] 只剩 key type），ParseAuthorizedKey 必失败。
    // 修法（零服务端改动）：公钥与 label 整体单引号聚合进 argv 元素。
    // 公钥先剥 comment 只留 "type blob"——注册本就不需要 comment，且 blob 恒为
    // base64，引号内不会再出现单引号冲突；label 为自由文本，引号防拆词（含单引号
    // 的 label 属已知残留）；ENROLL_CODE 为 hex 无空格，不加引号。
    const key = pubkey.trim().split(/\s+/).slice(0, 2).join(' ')
    const r = await ssh(['enroll-key', `'${key}'`, `'${label}'`, ENROLL_CODE])
    if (r.err) return fail(r, 'enroll-key')
    return text(r.stdout.trim())
  },
)

server.registerTool(
  'remove',
  {
    description: '销毁 box（磁盘数据一并删除，不可恢复！）。确认用户意图后再调用。',
    inputSchema: { box: z.string().describe('box 名') },
    annotations: { destructiveHint: true },
  },
  async ({ box }) => {
    const r = await ssh(['rm', box])
    if (r.err) return fail(r, 'rm')
    return text(r.stdout.trim())
  },
)

await server.connect(new StdioServerTransport())
