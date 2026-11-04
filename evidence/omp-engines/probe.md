# omp:opencode probe

profile glen-harness-opencode, omp/18.14.0

```json
{
  "ids": {
    "gemini-4-argon": true,
    "qwen3.8-max": true,
    "glm-5.3": true,
    "kimi-k3.1-pro": true,
    "deepseek-v4.1-flash": true,
    "glm-5.3-flash": true
  },
  "launch_mechanism": "overlay",
  "env_passthrough": true,
  "login_store_ok": false,
  "cap_signal": "unknown",
  "tools_ok": {
    "argon": true,
    "qwen": true,
    "glm": true,
    "flash": true
  },
  "no_tools_flag": true,
  "probed_at": "2026-11-04T21:53:34Z"
}
```

Notes

- omp usage keys: capacity.opencode-go.0.accounts,capacity.opencode-go.0.durationMs,capacity.opencode-go.0.remainingAccounts,capacity.opencode-go.0.usedAccounts,capacity.opencode-go.0.window,capacity.opencode-go.1.accounts,capacity.opencode-go.1.durationMs,capacity.opencode-go.1.remainingAccounts,capacity.opencode-go.1.usedAccounts,capacity.opencode-go.1.window,capacity.opencode-go.2.accounts,capacity.opencode-go.2.remainingAccounts,capacity.opencode-go.2.usedAccounts,capacity.opencode-go.2.window,generatedAt,reports.0.fetchedAt,reports.0.limits.0.amount.remainingFraction,reports.0.limits.0.amount.unit,reports.0.limits.0.amount.used,reports.0.limits.0.amount.usedFraction
