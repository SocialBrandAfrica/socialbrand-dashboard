# SQL deployment workflow

**Never use browser automation to paste SQL into Supabase.** It is slow, fragile, and adds 10+ minutes.

## The correct flow

1. CC writes the SQL file into `sql/` and tells Pieter the path.
2. Pieter opens the file, copies the content, pastes it into the Supabase SQL editor, runs it.
3. Pieter pastes the result text (or the error) back into the chat.
4. CC reads the result, confirms pass/fail, and commits.

Example handoff line from CC:
> "SQL ready at `sql/fix_rpc_top20_ean_ambiguous.sql` — paste it into Supabase and send back the result rows."

## Screenshots and OCR

When Pieter is present, never use screenshots to read UI state.
- Ask for PowerShell/curl output as text.
- Ask "what does the panel show?" — Pieter answers in a few words.
- Only use screenshots for layouts or visual bugs that cannot be described.

## Cheaper verification

Prefer REST API calls (PowerShell Invoke-WebRequest) over browser navigation for API checks.
Prefer JSON output over rendered HTML for data checks.
