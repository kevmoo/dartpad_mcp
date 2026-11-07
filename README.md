Zero-dependency local Model Context Protocol (MCP) bridge for DartPad Preview.

Connects desktop and CLI coding agents (`Claude Code`, `Gemini CLI`, `Cursor`,
`Antigravity`) to a live DartPad Preview browser tab over a loopback WebSocket
(`ws://127.0.0.1:8787/mcp-ws`) so agents can read/write files, run `pub`, check
analyzer diagnostics, hot-reload Flutter apps, and inspect the live VM Service
widget tree without a local Flutter SDK.

## Quick Start

Start the local bridge directly from GitHub with Dart `3.12+` (zero package
dependencies):

```bash
dart run 'dartpad_mcp@{git: https://github.com/kevmoo/dartpad_mcp}'
```

Or install it as a native `dartpad_mcp` executable:

```bash
dart install 'dartpad_mcp@{git: https://github.com/kevmoo/dartpad_mcp}'
dartpad_mcp
```

Because [bin/dartpad_mcp.dart](bin/dartpad_mcp.dart) uses only `dart:io`, it
also runs as a standalone single-file script without `git` or `pub`:

```bash
curl -fsSL https://raw.githubusercontent.com/kevmoo/dartpad_mcp/main/bin/dartpad_mcp.dart -o /tmp/dartpad_mcp.dart
dart /tmp/dartpad_mcp.dart
```

## Connecting a DartPad Preview Tab

1. Open [dartpad-webmcp.web.app/?s=3](https://dartpad-webmcp.web.app/?s=3) in
   Chrome and click **Connect Agent** in the top bar (or append `?mcp_port=8787`
   to the URL).
   - **Browser prompt**: When an `https://` DartPad host connects to
     `ws://127.0.0.1:8787/mcp-ws`, click **Allow** if Chrome prompts for Local
     Network Access. Safari blocks `https://` pages from opening
     `ws://127.0.0.1` loopback WebSockets.
   - **Remote SSH hosts**: The browser dials `127.0.0.1` on the machine running
     Chrome. If your coding agent runs over SSH on another host, forward the
     bridge port (`ssh -L 8787:127.0.0.1:8787`).
2. Verify the tab connected:
   ```bash
   dartpad_mcp status --require-tab
   ```

## MCP Client Configuration

### Streamable HTTP (`http://127.0.0.1:8787/mcp`)

```bash
claude mcp add --transport http dartpad http://127.0.0.1:8787/mcp
```

### Stdio (`--stdio`)

`--stdio` binds `:8787` when no bridge is running yet, and automatically
attaches to `http://127.0.0.1:8787/mcp` if a daemon is already active:

```json
{
  "mcpServers": {
    "dartpad": {
      "command": "dart",
      "args": [
        "run",
        "dartpad_mcp@{git: https://github.com/kevmoo/dartpad_mcp}",
        "--stdio"
      ]
    }
  }
}
```

## Direct CLI Tool Calls (No Agent Restart Needed)

Agents that are already mid-session can invoke tools immediately over CLI before
reloading MCP server configurations:

```bash
dartpad_mcp tools
dartpad_mcp call dartpad_get_status
dartpad_mcp call dartpad_run_or_reload '{"action":"hot_reload"}'
dartpad_mcp call dartpad_write_files --stdin << 'EOF'
{
  "files": [
    {
      "path": "lib/main.dart",
      "content": "void main() => print('Hello from MCP!');\n"
    }
  ]
}
EOF
```
