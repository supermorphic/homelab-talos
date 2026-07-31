@AGENTS.md

## Claude Code specifics

- Use plan mode before cross-cutting or multi-phase changes.
- Use read-only Explore subagents for repo-wide analysis instead of reading many
  files into the main context.
- Stay within this repository unless explicitly directed otherwise.
- Your external persistent memory index (`MEMORY.md`, outside this repository)
  records hard-won lessons; verify every repository path or recipe it names before acting.
