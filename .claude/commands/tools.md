# Load browser tools

Pre-load the Chrome MCP and computer-use tool schemas so they can be called without an extra ToolSearch round-trip.

Run this ToolSearch call now:

```
ToolSearch({
  query: "select:mcp__Claude_in_Chrome__browser_batch,mcp__Claude_in_Chrome__javascript_tool,mcp__Claude_in_Chrome__computer,mcp__Claude_in_Chrome__find,mcp__Claude_in_Chrome__navigate,mcp__Claude_in_Chrome__tabs_context_mcp,mcp__Claude_in_Chrome__get_page_text,mcp__Claude_in_Chrome__read_page,mcp__Claude_in_Chrome__form_input,mcp__Claude_in_Chrome__tabs_create_mcp,mcp__Claude_in_Chrome__read_network_requests,mcp__Claude_in_Chrome__read_console_messages,mcp__computer-use__screenshot,mcp__computer-use__request_access,mcp__ccd_session__mark_chapter",
  max_results: 15
})
```

After the ToolSearch completes, confirm: "Browser tools loaded (N schemas ready)" and list the tool names returned.
