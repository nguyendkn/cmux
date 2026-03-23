# AGENTS.md

This repository is the OpenCode port of the vibe-cokit Claude Code kit.

- `.opencode/agents/` contains the custom OpenCode subagents.
- `opencode.jsonc` contains the command registry and project OpenCode settings.
- `docs/opencode/` replaces the old `.claude/workflows/` references.

Follow YAGNI, KISS, and DRY. Prefer the `/vk:*` commands for the ported vibe-cokit workflows. Check skills in `.opencode/skills/*/SKILL.md`, then `~/.config/opencode/skills/*/SKILL.md`, then Claude-compatible fallback locations.
