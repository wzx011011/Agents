# OpenClaw Migration Bundle

Use this directory as the migration input for OpenClaw.

## Recommended usage

- If your OpenClaw version can read Claude-compatible assets, point it at claude-compatible/.claude/.
- Otherwise, use manifest.json and map agents, rules, and workspace memory manually.
- Use claude-compatible/.claude/CLAUDE.md as the workspace memory entrypoint.
- Use workflow.json to preserve PM -> Dev -> Review -> Test handoff semantics during manual mapping.
