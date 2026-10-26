import type { Dispatch } from '../types'

// Pure layout helpers for the dispatch band (tested in tests/layout.test.ts).

const SPARK = '▁▂▃▄▅▆▇█'
const PULSE = ['◉', '◎', '○', '◎']

export const rowKey = (r: Pick<Dispatch, 'executor' | 'task'>) => `${r.executor}-${r.task}`
export const cut = (s: string, n: number) => (s.length <= n ? s : s.slice(0, Math.max(0, n - 1)) + '…')
export const mins = (s: number) =>
  s >= 3600 ? `${Math.floor(s / 3600)}h${String(Math.floor((s % 3600) / 60)).padStart(2, '0')}` : `${Math.max(1, Math.round(s / 60))}m`

/** Column widths for the terminal width: wide shows everything, narrow drops the command and files/tests. */
export function tier(width: number): { task: number; label: number; doing: number; meta: boolean } {
  if (width >= 160) return { task: 20, label: 20, doing: Math.max(20, width - 120), meta: true }
  if (width >= 120) return { task: 18, label: 16, doing: Math.max(16, width - 100), meta: false }
  return { task: 16, label: 12, doing: 0, meta: false }
}

/** Smoothed bars on a baseline that never breaks, one scale shared by every row. */
export function activityBars(h: number[] | undefined, n: number, max: number): string {
  const x = (h ?? []).slice(-n)
  const v = [...Array(Math.max(0, n - x.length)).fill(0), ...x] as number[]
  const s = v.map((y, i) => ((v[i - 1] ?? y) + y * 2 + (v[i + 1] ?? y)) / 4)
  return s.map(y => SPARK[Math.min(7, Math.round(Math.sqrt(Math.max(0, y) / Math.max(1, max)) * 7))]).join('')
}

/** Stage dots: done ●, current pulses while live, to-do ○. No PROGRESS notes → no dots (never a fake stage). */
export function stageDots(r: Pick<Dispatch, 'stage' | 'of'>, f: number, live: boolean): string {
  if (!r.stage || !r.of) return ''
  const n = Math.min(10, r.of)
  const cur = Math.min(n, r.stage)
  const parts: string[] = []
  for (let i = 1; i <= n; i++) {
    parts.push(i < cur ? '●' : i === cur ? (live ? (PULSE[f % PULSE.length] ?? '◉') : '●') : '○')
    if (i < n) parts.push(i < cur ? '━' : '┄')
  }
  return parts.join('')
}

/** A job the usage forecast is holding: "waiting · codex full · starts ~21:40" (local time of fits_at). */
export function waitText(r: Pick<Dispatch, 'fits_at' | 'window'>, nowSec: number): string {
  const at = r.fits_at ?? 0
  const when = at > nowSec ? `starts ~${hhmm(at)}` : 'starting soon'
  return ['waiting', r.window ? `${r.window} full` : '', when].filter(Boolean).join(' · ')
}
export const hhmm = (sec: number) => {
  const d = new Date(sec * 1000)
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
}
