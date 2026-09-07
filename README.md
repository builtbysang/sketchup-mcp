# SketchupMCP - Sketchup Model Context Protocol Integration

SketchupMCP connects Sketchup to Claude AI through the Model Context Protocol (MCP), allowing Claude to directly interact with and control Sketchup. This integration enables prompt-assisted 3D modeling, scene creation, and manipulation in Sketchup.

Big Shoutout to [Blender MCP](https://github.com/ahujasid/blender-mcp) for the inspiration and structure.

## Features

* **Two-way communication**: Connect Claude AI to Sketchup through a TCP socket connection
* **Component manipulation**: Create, modify, delete, and transform components in Sketchup
* **Material control**: Apply and modify materials and colors
* **Scene inspection**: Get detailed information about the current Sketchup scene
* **Selection handling**: Get and manipulate selected components
* **Ruby code evaluation**: Execute arbitrary Ruby code directly in SketchUp for advanced operations

## Components

The system consists of two main components:

1. **Sketchup Extension**: A Sketchup extension that creates a TCP server within Sketchup to receive and execute commands
2. **MCP Server (`sketchup_mcp/server.py`)**: A Python server that implements the Model Context Protocol and connects to the Sketchup extension

## Installation

### Python Packaging

We're using uv so you'll need to ```brew install uv```

### Sketchup Extension

1. Download or build the latest `.rbz` file
2. In Sketchup, go to Window > Extension Manager
3. Click "Install Extension" and select the downloaded `.rbz` file
4. Restart Sketchup

## Usage

### Starting the Connection

1. In Sketchup, go to Extensions > SketchupMCP > Start Server
2. The server will start on the default port (9876)
3. Make sure the MCP server is running in your terminal

### Using with Claude

Configure Claude to use the MCP server by adding the following to your Claude configuration:

```json
    "mcpServers": {
        "sketchup": {
            "command": "uvx",
            "args": [
                "sketchup-mcp"
            ]
        }
    }
```

This will pull the [latest from PyPI](https://pypi.org/project/sketchup-mcp/)

Once connected, Claude can interact with Sketchup using the following capabilities:

#### Tools

Inspection

* `get_scene_info` - Model summary: counts, bounds, units, top-level entities. Ids
  and names only by default; pass `detail=true` for bounding boxes, layers and
  materials, and `limit` to cap the entity list.
* `get_selection` - Ids and types of the current selection.

Geometry

* `create_component` - One primitive (`cube`, `cylinder`, `sphere`, `cone`).
* `create_components` - Many primitives in a single round trip and a single undo
  step. Prefer this over repeated `create_component` calls.
* `delete_component` / `transform_component` / `set_material`
* `boolean_operation` - `union`, `difference`, `intersection` between two groups.
* `chamfer_edges` / `fillet_edges`

Joinery

* `create_mortise_tenon` / `create_dovetail` / `create_finger_joint`

Escape hatch

* `eval_ruby` - Run Ruby inside SketchUp. The cheapest way to build anything
  non-trivial: one call can create a whole assembly as one undo step. Local
  variables persist between calls, so you can keep a reference and reuse it
  later instead of re-sending context.

Output

* `export_scene` - Export and return the path written. `skp`, `obj`, `dae`,
  `stl`, `fbx`, `3ds`, `wrl`, `xsi`, `kmz`, `png`, `jpg`. Some exporters are
  SketchUp Pro only and say so rather than failing silently.

All geometry values are inches, whatever the model's display units.

### Configuration

Every setting has a working default; both sides read the same environment.

| Variable | Default | Effect |
|---|---|---|
| `SKETCHUP_MCP_HOST` | `127.0.0.1` | Bind/connect address |
| `SKETCHUP_MCP_PORT` | `9876` | Bridge port |
| `SKETCHUP_MCP_TIMEOUT` | `60` | Seconds to wait for a reply (Python side) |
| `SKETCHUP_MCP_MAX_CHARS` | `4000` | Cap on a single tool result |
| `SKETCHUP_MCP_MAX_ITEMS` | `100` | Cap on entity lists |
| `SKETCHUP_MCP_EXPORT_DIR` | system temp | Where `export_scene` writes |
| `SKETCHUP_MCP_DEBUG` | unset | Open the Ruby Console and log every request |

The extension no longer forces the Ruby Console open; set `SKETCHUP_MCP_DEBUG=1`
before launching SketchUp when you want the log. Extensions > MCP Server >
Server Status reports whether the bridge is listening.

### Tests

`ruby tests/test_extension.rb` and `python3 tests/test_transport.py` — neither
needs SketchUp or an MCP client. See [tests/README.md](tests/README.md).

### Example Commands

Here are some examples of what you can ask Claude to do:

* "Create a simple house model with a roof and windows"
* "Select all components and get their information"
* "Make the selected component red"
* "Move the selected component 10 units up"
* "Export the current scene as a 3D model"
* "Create a complex arts and crafts cabinet using Ruby code"

## Troubleshooting

* **Connection issues**: Make sure the extension server is started
  (Extensions > MCP Server > Start Server). The MCP server reconnects on its own.
* **Command failures**: Run SketchUp with `SKETCHUP_MCP_DEBUG=1` and read the
  Ruby Console.
* **Timeout errors**: A timed-out request is *not* resent, because the extension
  is not idempotent — a replayed `create_component` would build the shape twice.
  Raise `SKETCHUP_MCP_TIMEOUT` for long operations instead of retrying.

## Technical Details

### Communication Protocol

The system uses a simple JSON-based protocol over TCP sockets:

* **Commands** are sent as JSON objects with a `type` and optional `params`
* **Responses** are JSON objects with a `status` and `result` or `message`

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT 