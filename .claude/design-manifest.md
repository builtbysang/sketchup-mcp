# Design manifest — sketchup-mcp

Scanned 2026-09-08. **This repo has no design system.** No design docs, no token
file, no stylesheet, no component directory, no stories. Every UI surface is
SketchUp's own Ruby API.

## What exists

| Layer | Where | Notes |
|---|---|---|
| Menu | `su_mcp/su_mcp/main.rb` (bottom) | `UI.menu("Plugins")` submenu "Phanton Sketchup MCP". One `UI::Command` per window, built by walking `DIALOGS`: Máy chủ MCP, Tầng nhà, Tuyến ống, Thống kê ống, Cài đặt. Nothing starts the server from the menu any more — that moved inside its window. |
| Toolbar | same file | Reuses the **same `UI::Command` objects** as the menu, so state and labels can never diverge. `toolbar.restore` remembers whether it was showing. Icons: `su_mcp/su_mcp/icons/dialog-*-32.png` and `-48.png`. |
| Panels | `su_mcp/su_mcp/panels/*.html` | One `UI::HtmlDialog` per window, all sharing `panels/panel.css`. A page owns no truth: it calls `ready()` on load and Ruby answers by calling `render(state)` into it. |

## Inventory

| Component | Source | Reused by |
|---|---|---|
| `UI::Command` × 3 | main.rb | menu + toolbar (one object each, two surfaces) |
| Panel status block | panel.html | — |
| Panel button pair | panel.html | — |
| Panel checkbox row | panel.html | — |
| Panel schedule table | panel.html | — |
| Panel warning line | panel.html | the unlabelled-metres notice; `--warn`, never `--danger` (it is not an error) |

## Tokens

Declared as CSS custom properties at the top of `panel.html`, since there is
nothing repo-wide to inherit from. Panel colors are the same three that the
toolbar icons are rendered in, so the two surfaces read as one thing:

| Token | Value | Used for |
|---|---|---|
| `--ok` | `#2E7D32` | running dot, Start icon |
| `--danger` | `#B3261E` | error text, Stop icon |
| `--slate` | `#37474F` | panel icon, headings |
| `--muted` | `#6B7280` | address line, secondary text |
| `--line` | `#E0E0E0` | dividers |
| `--warn` | `#B26A00` | unlabelled metres — amber, so it cannot be read as a total or as an error |

## Icons

Iconoir 7.12.1 (MIT), `solid` set, rasterized to PNG at 48px (large) and 32px
(small) — 2× the documented 24/16 so they stay crisp on retina, which SketchUp
scales down. Source SVGs are colorized before rasterizing; `currentColor` does
not survive a PNG.

| Command | Iconoir name | Color |
|---|---|---|
| Start Server | `solid/play` | `--ok` |
| Stop Server | `solid/pause` | `--danger` |
| MCP Panel | `solid/server-connection` | `--slate` |

## Rules for future UI work here

- A new command belongs to **one** `UI::Command` object shared by menu and
  toolbar. Never build a second command with the same label.
- Panel colors come from the token block, not literals.
- Panel strings stay English, matching the existing menu labels.
- No blocking `UI.messagebox` for status. That was removed on purpose in
  1c6917f; the menu, toolbar and panel are the status readout.
