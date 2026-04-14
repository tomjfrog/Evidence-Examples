# Using the JFrog MCP Server in All Projects

Your JFrog MCP server is already configured **globally**, so it applies to every project. If the agent doesn’t see it (“Available servers: cursor-ide-browser” only), use these steps.

---

## 1. Confirm global config (already correct)

- **File:** `~/.cursor/mcp.json`
- **Meaning:** Anything here applies to **all** workspaces. No per-project file overrides it unless you add one.

Your config:

```json
{
  "mcpServers": {
    "jfrog": {
      "url": "https://tomjfrog.jfrog.io/mcp"
    }
  }
}
```

Keep this as-is. Do **not** add a project-level `.cursor/mcp.json` in a repo unless you want that project to use different MCP settings.

---

## 2. Ensure JFrog is enabled and connected in Cursor

1. Open **Cursor Settings**: `Cmd + ,` (macOS) or `Ctrl + ,` (Windows).
2. Go to **Tools & MCP** (or **MCP**).
3. Find **jfrog** / **JFrog** in the list.
4. Check:
   - **Status** is **Connected** (not Disconnected / Failed / Needs auth).
   - The server (and its tools) are **enabled** (toggles on).

If status is Failed or Disconnected, Cursor won’t expose the server to the agent. Fix connection first (step 3).

---

## 3. Fix connection and authentication

**If the server shows “Needs authentication” or never becomes “Connected”:**

- **In Cursor:** Use any “Connect” / “Authenticate” / “Sign in” action for the JFrog server in **Tools & MCP**. Complete the flow (browser OAuth or token prompt) so Cursor can store credentials.
- **From chat:** In a **new** Composer/Agent chat, ask: “Call the `mcp_auth` tool for the jfrog MCP server with empty arguments.” Once that succeeds, the server should become available in that session.

**If the server fails to connect at all:**

- Confirm `https://tomjfrog.jfrog.io/mcp` is reachable (e.g. open it in a browser or `curl -I https://tomjfrog.jfrog.io/mcp`).
- If your JFrog MCP endpoint requires a bearer token or API key, add it to the global config (never commit real secrets):

```json
{
  "mcpServers": {
    "jfrog": {
      "url": "https://tomjfrog.jfrog.io/mcp",
      "headers": {
        "Authorization": "Bearer YOUR_ACCESS_TOKEN"
      }
    }
  }
}
```

Replace `YOUR_ACCESS_TOKEN` with a token that has access to the MCP endpoint. Then restart Cursor.

---

## 4. Avoid the 40-tool limit

Cursor exposes roughly **40 MCP tools total** across all servers. If you have many servers or tools, some can be dropped and the agent won’t see them.

- In **Settings > Tools & MCP**, open each server and **disable tools you don’t need**.
- Prefer keeping **jfrog**’s tools enabled and turning off less-used tools on other servers so JFrog stays within the active set.

---

## 5. Restart Cursor after config changes

After editing `~/.cursor/mcp.json` or changing MCP settings, **fully quit and reopen Cursor** so it reloads MCP servers and exposes them to the agent.

---

## 6. Keep “jfrog” for all projects (no override)

- **To use JFrog everywhere:** Leave only `~/.cursor/mcp.json` with the `jfrog` entry. Do **not** create `.cursor/mcp.json` in project roots unless you want that project to have different MCP config.
- **If a project has its own `.cursor/mcp.json`:** That file overrides the global one for that project. To have JFrog there too, add the same `jfrog` block to the project’s `mcp.json` or remove the project-level file to fall back to global.

---

## Quick checklist

| Step | Action |
|------|--------|
| 1 | Config is in `~/.cursor/mcp.json` (global) ✓ |
| 2 | **Settings > Tools & MCP**: JFrog shows **Connected** and is **enabled** |
| 3 | Complete any **auth** (UI or `mcp_auth`) and add `headers` in mcp.json if the endpoint needs a token |
| 4 | **Disable** unused tools on other servers to stay under the ~40-tool limit |
| 5 | **Restart Cursor** after any mcp.json or MCP setting change |

After this, the “jfrog” / “JFrog” MCP server should be available to the agent in all projects that use the global config.
