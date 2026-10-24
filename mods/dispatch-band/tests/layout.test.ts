import { describe, expect, test } from 'claude-code/testing'

import { activityBars, cut, mins, rowKey, stageDots, tier } from '../hooks/layout'

describe('stage dots', () => {
  test('done, current and to-do stages', () => {
    expect(stageDots({ stage: 3, of: 5 }, 0, false)).toBe('●━●━●┄○┄○')
  })
  test('current stage pulses only while the job works', () => {
    expect(stageDots({ stage: 2, of: 3 }, 1, true)).toBe('●━◎┄○')
    expect(stageDots({ stage: 2, of: 3 }, 1, false)).toBe('●━●┄○')
  })
  test('no progress notes means no dots, never a made-up stage', () => {
    expect(stageDots({ stage: null, of: null }, 3, true)).toBe('')
  })
})

describe('activity bars (D1)', () => {
  test('a job with no history is a flat baseline, never blank', () => {
    expect(activityBars(undefined, 8, 1)).toBe('▁▁▁▁▁▁▁▁')
  })
  test('always the requested width; busiest sample reaches the top', () => {
    const s = activityBars([0, 0, 100, 400, 100, 0], 8, 400)
    expect(s.length).toBe(8)
    expect(s.includes(' ')).toBe(false)
    expect(s.includes('█') || s.includes('▇')).toBe(true)
  })
  test('one shared scale: a small job stays low next to a big one', () => {
    const small = activityBars([10, 10, 10], 4, 1000)
    expect(/[▅▆▇█]/.test(small)).toBe(false)
  })
})

describe('columns and helpers', () => {
  test('narrow terminals drop the command and files/tests', () => {
    expect(tier(100)).toEqual({ task: 16, label: 12, doing: 0, meta: false })
    expect(tier(200).meta).toBe(true)
  })
  test('codex and gemini jobs with the same name never share a row', () => {
    expect(rowKey({ executor: 'codex', task: 'x' })).not.toBe(rowKey({ executor: 'agy', task: 'x' }))
  })
  test('cut and minutes', () => {
    expect(cut('abcdef', 4)).toBe('abc…')
    expect(mins(30)).toBe('1m')
    expect(mins(3900)).toBe('1h05')
  })
})
