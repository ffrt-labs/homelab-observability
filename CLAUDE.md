## This repo

The observability stack for the home server. `SPEC.md` is the design of record — read it,
including its **Amendments** section, before proposing anything. Its **Roadmap** section
holds the ship sequence, which deliberately differs from the alert priority ordering.

## Agent skills

### Issue tracker

Issues live in GitHub Issues (`ffrt-labs/homelab-observability`), via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five canonical labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root (created lazily). See `docs/agents/domain.md`.
