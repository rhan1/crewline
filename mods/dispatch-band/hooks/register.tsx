import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { Dispatch } from '../types'
import { activityBars, cut, mins, rowKey, stageDots, tier, waitText } from './layout'

// Dispatch band (2026-10-25): one line per Codex / Gemini job THIS session dispatched —
// activity graph (D1 smoothed bars), stage dots, stage, time, what it is doing now, files/tests.
// Data: bin/dispatch-view.py (bundled) --session-pid <this claude pid>. /dispatches on|off.
// Jobs the usage forecast is holding (quota-forecast.mjs queue) show as faint 'waiting · … · starts ~HH:MM' rows.
// Claude's own subagents stay out: Claude Code draws them below the prompt and no mod can hide that list.

const PYTHONS = ['/opt/homebrew/bin/python3', '/usr/bin/python3']
const rows = atom({ plugin: 'dispatch-band', key: 'rows' } as const, [] as Dispatch[])
const history = atom({ plugin: 'dispatch-band', key: 'history' } as const, {} as Record<string, number[]>)
const frame = atom({ plugin: 'dispatch-band', key: 'frame' } as const, 0)
const isOn = atom({ plugin: 'dispatch-band', key: 'isOn' } as const, true)

const CODEX = '#10a37f'
const GEMINI = '#a78bfa'
const AMBER = '#f5a623'
const FAINT = '#6b7280'
const QUIET_SECS = 180
const GRAPH = 16
const MAX_ROWS = 8

const isActive = (r: Dispatch) => !r.waiting && (r.quiet === null || r.quiet < QUIET_SECS)
const vendor = (r: Dispatch) => (r.executor === 'codex' ? CODEX : GEMINI)

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'dispatches', description: 'Show or hide the running-dispatches band: /dispatches on | off' })
    if ((await $.store.get('on')) === false) await update($, isOn, () => false)

    // This session's Claude pid: Claude Code exports CLAUDE_PID to its children and the dispatch markers
    // record it; fall back to the nearest claude process above a shell the engine starts.
    let me = ((await $.env.get('CLAUDE_PID').catch(() => undefined)) ?? '').trim()
    if (!/^\d+$/.test(me)) {
      const r = await $.process
        .run(['/bin/sh', '-c', 'p=$PPID; for i in 1 2 3; do ps -o command= -p $p | grep -q claude && { echo $p; exit; }; p=$(ps -o ppid= -p $p | tr -d " "); done'])
        .catch(() => undefined)
      me = (r?.stdout ?? '').trim()
    }
    const scoped = /^\d+$/.test(me)

    const helper = `${$.plugin.root}/bin/dispatch-view.py`
    let python = PYTHONS[1]!
    for (const p of PYTHONS) {
      if (await $.fs.exists(p).catch(() => false)) { python = p; break }
    }

    let busy = false
    const poll = async () => {
      if (busy || !(await read($, isOn))) return
      busy = true
      try {
        const res = await $.process
          .run([python, '-I', helper, ...(scoped ? ['--session-pid', me] : [])], { timeoutMs: 15000 })
          .catch(() => undefined)
        if (!res || res.exitCode !== 0) return
        let list: Dispatch[] = []
        try { list = JSON.parse(res.stdout) } catch { return }
        const prev = await read($, rows)
        if (list.length === 0 && prev.length === 0) return
        const before = new Map(prev.map(r => [rowKey(r), r.log_bytes]))
        await update($, history, h => {
          const out: Record<string, number[]> = {}
          for (const r of list) {
            const k = rowKey(r)
            const delta = before.has(k) ? Math.max(0, r.log_bytes - (before.get(k) ?? 0)) : 0
            out[k] = [...(h[k] ?? []), delta].slice(-GRAPH * 2)
          }
          return out
        })
        await update($, rows, () => list)
      } finally {
        busy = false
      }
    }
    void poll()
    // every 5 s while this session has jobs, every 15 s while it has none
    let idleTicks = 0
    $.clock.every(5000, () => {
      void (async () => {
        const has = (await read($, rows)).length > 0
        if (has || ++idleTicks >= 3) { idleTicks = 0; await poll() }
      })()
    })
    // the pulsing stage dot: redraw only while a job is actually working
    $.clock.every(500, () => {
      void (async () => {
        if ((await read($, rows)).some(isActive) && (await read($, isOn))) await update($, frame, f => (f + 1) % 1000)
      })()
    })
    return next(e)
  })

  on('command.run', { command: 'dispatches' }, async ($, e) => {
    const arg = (e.args || '').trim().toLowerCase()
    if (arg !== 'on' && arg !== 'off') {
      return { text: `Dispatch band is ${(await read($, isOn)) ? 'on' : 'off'}. Use /dispatches on or /dispatches off.` }
    }
    await update($, isOn, () => arg === 'on')
    await $.store.set('on', arg === 'on')
    return { text: `Dispatch band ${arg}.` }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const list = await read($, rows)
    if (e.props.hasSurvey || !(await read($, isOn)) || list.length === 0) return next(e)
    const f = await read($, frame)
    const hist = await read($, history)
    const t = tier(e.props.bodyColumns ?? 120)
    const { Box, Text } = $.ui.resolve(e)
    const shown = list.slice(0, Math.max(1, Math.min(MAX_ROWS, (e.props.maxRows ?? 12) - 3)))
    const gmax = Math.max(1, ...shown.flatMap(r => (hist[rowKey(r)] ?? []).slice(-GRAPH)))
    const dotsW = Math.max(0, ...shown.map(r => stageDots(r, 0, false).length))
    const labelOf = (r: Dispatch) => (r.stage && r.of ? `${r.stage}/${r.of} ${r.stage_name ?? ''}` : isActive(r) ? 'working' : '')
    const labelW = Math.min(t.label, Math.max(0, ...shown.map(r => labelOf(r).length)))
    const running = list.filter(r => !r.waiting)
    const nWait = list.length - running.length
    const nCodex = running.filter(r => r.executor === 'codex').length
    const nowSec = Date.now() / 1000

    return (
      <Box flexDirection="column" marginTop={1} key="band">
        <Box key="hdr">
          <Text bold>dispatches </Text>
          <Text color={FAINT}>{running.length} running in this session · </Text>
          <Text color={CODEX}>{nCodex} codex</Text>
          <Text color={FAINT}> · </Text>
          <Text color={GEMINI}>{running.length - nCodex} gemini</Text>
          {nWait > 0 && <Text color={AMBER}> · {nWait} waiting</Text>}
        </Box>
        {shown.map(r => {
          if (r.waiting) {
            return (
              <Box key={`wait-${rowKey(r)}`}>
                <Text color={vendor(r)}>{r.executor === 'codex' ? '◆' : '◇'} </Text>
                <Text bold wrap="truncate-end">{cut(r.task, t.task).padEnd(t.task)} </Text>
                <Text color={FAINT}>{'┄'.repeat(GRAPH)} </Text>
                <Text color={AMBER} wrap="truncate-end">{waitText(r, nowSec)}</Text>
                <Text color={FAINT}>  queued {mins(r.elapsed)}</Text>
              </Box>
            )
          }
          const live = isActive(r)
          const meta = [r.files ? `${r.files} files` : '', r.tests ?? ''].filter(Boolean).join(' · ')
          return (
            <Box key={rowKey(r)}>
              <Text color={vendor(r)}>{r.executor === 'codex' ? '◆' : '◇'} </Text>
              <Text bold wrap="truncate-end">{cut(r.task, t.task).padEnd(t.task)} </Text>
              <Text color={live ? vendor(r) : AMBER}>{activityBars(hist[rowKey(r)], GRAPH, gmax)} </Text>
              {dotsW > 0 && <Text color={live ? vendor(r) : AMBER}>{stageDots(r, f, live).padEnd(dotsW)} </Text>}
              {labelW > 0 && <Text color={FAINT} wrap="truncate-end">{cut(labelOf(r), labelW).padEnd(labelW)} </Text>}
              <Text>{mins(r.elapsed).padStart(4)} </Text>
              {!live && <Text color={AMBER}>quiet {mins(r.quiet ?? 0)} </Text>}
              {t.doing > 0 && <Text dimColor wrap="truncate-end">{cut(r.doing || r.what, t.doing)}</Text>}
              {t.meta && meta && <Text color={FAINT} wrap="truncate-end">  {meta}</Text>}
            </Box>
          )
        })}
        {list.length > shown.length && <Text color={FAINT} key="more">  +{list.length - shown.length} more</Text>}
      </Box>
    )
  })
}
