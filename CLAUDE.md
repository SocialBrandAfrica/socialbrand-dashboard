# SocialBrand Dashboard — Project Instructions

## Session startup (run this first, every session)

Before reading any handover file or doing any work, call ToolSearch once to pre-load the browser and session tool schemas:

```
ToolSearch({
  query: "select:mcp__Claude_in_Chrome__browser_batch,mcp__Claude_in_Chrome__javascript_tool,mcp__Claude_in_Chrome__computer,mcp__Claude_in_Chrome__find,mcp__Claude_in_Chrome__navigate,mcp__Claude_in_Chrome__tabs_context_mcp,mcp__Claude_in_Chrome__get_page_text,mcp__Claude_in_Chrome__read_page,mcp__Claude_in_Chrome__form_input,mcp__Claude_in_Chrome__tabs_create_mcp,mcp__Claude_in_Chrome__read_network_requests,mcp__Claude_in_Chrome__read_console_messages,mcp__computer-use__screenshot,mcp__computer-use__request_access,mcp__ccd_session__mark_chapter",
  max_results: 15
})
```

Do not skip this step — these tools appear as deferred and will fail with InputValidationError if called without loading first.

After the ToolSearch, proceed normally (read handover, run session tasks, etc.).

---

## Project context

See memory files for full project context:
- `memory/MEMORY.md` — index of all memory files
- Handover files live in `C:\Users\User\Desktop\DIWAAIS\` — read the latest on session start

## Key rules

- No Unicode in `.ps1` files — store servers are Windows-1252
- All scripts go in `socialbrand-dashboard/scripts/`; server output to `C:\socialbrand\` on store servers
- Full SQL files: fix the file in `sql/`, reference with path only — never dump full SQL in chat
- ASCII-only commit messages and PowerShell scripts
- Never edit code concurrently with a Cowork Claude — check who owns the file first
