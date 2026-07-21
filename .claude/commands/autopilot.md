# Autopilot — Load browser tools

Pre-load the Chrome MCP and computer-use tool schemas so they can be called without an extra ToolSearch round-trip.

Run this ToolSearch call now:

```
ToolSearch({
  query: "select:mcp__claude-in-chrome__browser_batch,mcp__claude-in-chrome__javascript_tool,mcp__claude-in-chrome__computer,mcp__claude-in-chrome__find,mcp__claude-in-chrome__navigate,mcp__claude-in-chrome__tabs_context_mcp,mcp__claude-in-chrome__get_page_text,mcp__claude-in-chrome__read_page,mcp__claude-in-chrome__form_input,mcp__claude-in-chrome__tabs_create_mcp,mcp__claude-in-chrome__read_network_requests,mcp__claude-in-chrome__read_console_messages,mcp__computer-use__screenshot,mcp__computer-use__request_access,mcp__ccd_session__mark_chapter",
  max_results: 15
})
```

After the ToolSearch completes, confirm: "Autopilot ready (N schemas loaded)" and list the tool names returned.
