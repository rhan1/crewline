export type Dispatch = {
  executor: string; task: string; model: string; profile: string
  parent_pid?: number | null
  elapsed: number; quiet: number | null; log_bytes: number
  session: string; what: string
  stage?: number | null; of?: number | null; stage_name?: string
  doing?: string; files?: number; tests?: string; steps?: number
}

declare module 'claude-code' {
  interface PluginState {
    'dispatch-band': {
      rows: Dispatch[]
      history: Record<string, number[]>
      frame: number
      isOn: boolean
    }
  }
}
