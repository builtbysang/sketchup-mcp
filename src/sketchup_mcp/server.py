"""MCP server that drives SketchUp through the su_mcp extension's TCP socket."""

from mcp.server.fastmcp import FastMCP
import itertools
import json
import logging
import os
import socket
import threading
from contextlib import asynccontextmanager
from typing import Any, AsyncIterator, Dict, List, Optional

__version__ = "0.1.18"

HOST = os.environ.get("SKETCHUP_MCP_HOST", "127.0.0.1")
PORT = int(os.environ.get("SKETCHUP_MCP_PORT", "9876"))
TIMEOUT = float(os.environ.get("SKETCHUP_MCP_TIMEOUT", "60"))
MAX_CHARS = int(os.environ.get("SKETCHUP_MCP_MAX_CHARS", "4000"))
DEBUG = bool(os.environ.get("SKETCHUP_MCP_DEBUG"))

logging.basicConfig(
    level=logging.DEBUG if DEBUG else logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger("SketchupMCPServer")


class SketchupError(Exception):
    """Anything that went wrong talking to, or inside, SketchUp."""


class SketchupConnection:
    """One persistent, newline-framed JSON-RPC socket to the SketchUp extension.

    The extension keeps the connection open across requests and answers each
    line with exactly one line, tagged with the request id it was given.
    """

    def __init__(self, host: str, port: int, timeout: float) -> None:
        self.host = host
        self.port = port
        self.timeout = timeout
        self.sock: Optional[socket.socket] = None
        self._buffer = b""
        self._ids = itertools.count(1)
        self._lock = threading.Lock()

    # -- socket lifecycle -------------------------------------------------

    def connect(self) -> None:
        if self.sock is not None:
            return
        sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
        sock.settimeout(self.timeout)
        self.sock = sock
        self._buffer = b""
        logger.info("Connected to SketchUp at %s:%s", self.host, self.port)

    def close(self) -> None:
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None
        self._buffer = b""

    # -- request/response -------------------------------------------------

    def call(self, tool: str, arguments: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        with self._lock:
            return self._call(tool, arguments or {})

    def _call(self, tool: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        request_id = next(self._ids)
        payload = json.dumps(
            {
                "jsonrpc": "2.0",
                "method": "tools/call",
                "params": {"name": tool, "arguments": arguments},
                "id": request_id,
            }
        ).encode("utf-8") + b"\n"

        logger.debug("-> %s %s", tool, _preview(arguments))

        # A failure before any byte reaches SketchUp is safe to retry. Once the
        # request is on the wire it must never be resent: the extension is not
        # idempotent, and a replayed create_component builds the shape twice.
        try:
            self.connect()
            self.sock.sendall(payload)  # type: ignore[union-attr]
        except OSError as first:
            logger.info("Send failed (%s); reconnecting once", first)
            self.close()
            try:
                self.connect()
                self.sock.sendall(payload)  # type: ignore[union-attr]
            except OSError as second:
                self.close()
                raise SketchupError(
                    f"Cannot reach SketchUp at {self.host}:{self.port} ({second}). "
                    "Open SketchUp, then Extensions > MCP Server > Start Server."
                ) from second

        return self._await_response(request_id, tool)

    def _await_response(self, request_id: int, tool: str) -> Dict[str, Any]:
        while True:
            try:
                message = self._read_message()
            except socket.timeout:  # aliased to TimeoutError from 3.10, still a
                                    # plain OSError subclass on 3.9 - catch it first
                self.close()
                raise SketchupError(
                    f"SketchUp did not answer '{tool}' within {self.timeout:.0f}s. "
                    "The request was NOT resent, so check the model for partial "
                    "geometry; raise SKETCHUP_MCP_TIMEOUT for long operations."
                ) from None
            except OSError as exc:
                self.close()
                raise SketchupError(f"Connection lost during '{tool}': {exc}") from exc

            if message.get("id") != request_id:
                logger.debug("Dropping stale response id=%r", message.get("id"))
                continue

            if "error" in message:
                error = message["error"] or {}
                raise SketchupError(error.get("message", "Unknown SketchUp error"))

            return message.get("result") or {}

    def _read_message(self) -> Dict[str, Any]:
        while b"\n" not in self._buffer:
            chunk = self.sock.recv(65536)  # type: ignore[union-attr]
            if not chunk:
                raise ConnectionError("SketchUp closed the connection")
            self._buffer += chunk

        line, self._buffer = self._buffer.split(b"\n", 1)
        text = line.strip()
        if not text:
            return {}

        try:
            message = json.loads(text.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise SketchupError(f"Invalid JSON from SketchUp: {exc}") from exc

        if not isinstance(message, dict):
            raise SketchupError(f"Unexpected response type from SketchUp: {type(message).__name__}")

        logger.debug("<- %s", _preview(message))
        return message


_connection: Optional[SketchupConnection] = None
_connection_lock = threading.Lock()


def get_sketchup_connection() -> SketchupConnection:
    global _connection
    with _connection_lock:
        if _connection is None:
            _connection = SketchupConnection(HOST, PORT, TIMEOUT)
        return _connection


def _preview(value: Any, limit: int = 300) -> str:
    text = value if isinstance(value, str) else json.dumps(value, default=str)
    return text if len(text) <= limit else f"{text[:limit]}... ({len(text)} chars)"


def _unwrap(result: Dict[str, Any], raw_text: bool) -> Dict[str, Any]:
    """Flatten the extension's MCP envelope back into plain data.

    The extension answers with {"content": [{"text": ...}], "resourceId": ...};
    the text is JSON for structured tools and a plain string for eval_ruby.
    """
    text: Optional[str] = None
    content = result.get("content")
    if isinstance(content, list) and content and isinstance(content[0], dict):
        text = content[0].get("text")

    payload: Dict[str, Any] = {"success": True}

    if text is not None:
        if raw_text:
            payload["result"] = text
        else:
            try:
                parsed = json.loads(text)
            except (TypeError, json.JSONDecodeError):
                payload["result"] = text
            else:
                if isinstance(parsed, dict):
                    payload.update(parsed)
                else:
                    payload["result"] = parsed

    if result.get("resourceId") is not None:
        payload.setdefault("id", result["resourceId"])

    return payload


def _respond(payload: Dict[str, Any]) -> str:
    """Serialise a tool result, keeping it inside the response budget."""
    text = json.dumps(payload)
    if MAX_CHARS <= 0 or len(text) <= MAX_CHARS:
        return text
    return json.dumps(
        {
            "success": payload.get("success", True),
            "truncated": True,
            "total_chars": len(text),
            "preview": text[:MAX_CHARS],
        }
    )


def call_tool(name: str, arguments: Dict[str, Any], raw_text: bool = False) -> str:
    """Run one extension tool and return its result as a JSON string."""
    try:
        result = get_sketchup_connection().call(name, arguments)
        return _respond(_unwrap(result, raw_text))
    except SketchupError as exc:
        return json.dumps({"success": False, "error": str(exc)})
    except Exception as exc:  # noqa: BLE001 - surfaced to the model, not swallowed
        logger.exception("Unexpected failure in %s", name)
        return json.dumps({"success": False, "error": f"{type(exc).__name__}: {exc}"})


@asynccontextmanager
async def server_lifespan(server: FastMCP) -> AsyncIterator[Dict[str, Any]]:
    logger.info("SketchupMCP %s starting (SketchUp at %s:%s)", __version__, HOST, PORT)
    try:
        yield {}
    finally:
        global _connection
        with _connection_lock:
            if _connection is not None:
                _connection.close()
                _connection = None
        logger.info("SketchupMCP shut down")


mcp = FastMCP(
    "SketchupMCP",
    instructions=(
        "Drive SketchUp over MCP. Geometry values are always inches, whatever "
        "the model's display units. For anything beyond a few primitives, write "
        "one eval_ruby script instead of many small calls - each tool call is a "
        "full round trip, and eval_ruby keeps its local variables between calls."
    ),
    lifespan=server_lifespan,
)


@mcp.tool()
def get_scene_info(detail: bool = False, limit: int = 100) -> str:
    """Summarise the active model: counts, bounds, units, top-level entities.

    Returns names and ids only by default. Set detail=True to also get each
    entity's bounding box plus the layer and material lists.
    """
    return call_tool("get_scene_info", {"detail": detail, "limit": limit})


@mcp.tool()
def get_selection() -> str:
    """List the ids and types of the currently selected entities."""
    return call_tool("get_selection", {})


@mcp.tool()
def create_component(
    type: str = "cube",
    position: List[float] = None,
    dimensions: List[float] = None,
) -> str:
    """Create one primitive (cube, cylinder, sphere, cone) and return its id.

    position is the corner [x, y, z]; dimensions is [width, depth, height], in
    inches. Use create_components when you need more than one shape.
    """
    return call_tool(
        "create_component",
        {
            "type": type,
            "position": position or [0, 0, 0],
            "dimensions": dimensions or [1, 1, 1],
        },
    )


@mcp.tool()
def create_components(components: List[Dict[str, Any]]) -> str:
    """Create many primitives in one round trip and one undo step.

    Each item takes the same keys as create_component, e.g.
    [{"type": "cube", "position": [0,0,0], "dimensions": [10,2,1]}, ...].
    Returns the new ids in the order given. Prefer this over repeated
    create_component calls: it costs one request instead of N.
    """
    return call_tool("create_components", {"components": components})


@mcp.tool()
def delete_component(id: str) -> str:
    """Delete an entity by id."""
    return call_tool("delete_component", {"id": id})


@mcp.tool()
def transform_component(
    id: str,
    position: List[float] = None,
    rotation: List[float] = None,
    scale: List[float] = None,
) -> str:
    """Move, rotate, or scale an entity. Omitted transforms are left alone."""
    arguments: Dict[str, Any] = {"id": id}
    if position is not None:
        arguments["position"] = position
    if rotation is not None:
        arguments["rotation"] = rotation
    if scale is not None:
        arguments["scale"] = scale
    return call_tool("transform_component", arguments)


@mcp.tool()
def set_material(id: str, material: str) -> str:
    """Apply a material or colour name (e.g. "red", "Wood_Cherry") to an entity."""
    return call_tool("set_material", {"id": id, "material": material})


@mcp.tool()
def boolean_operation(operation: str, target_id: str, tool_id: str) -> str:
    """Union, difference, or intersection between two groups/component instances.

    operation is one of "union", "difference", "intersection". difference cuts
    tool_id out of target_id - the usual way to make joinery and openings.
    """
    return call_tool(
        "boolean_operation",
        {"operation": operation, "target_id": target_id, "tool_id": tool_id},
    )


@mcp.tool()
def chamfer_edges(
    entity_id: str,
    distance: float = 0.25,
    edge_indices: List[int] = None,
) -> str:
    """Bevel the edges of an entity. Omit edge_indices to chamfer every edge."""
    arguments: Dict[str, Any] = {"entity_id": entity_id, "distance": distance}
    if edge_indices is not None:
        arguments["edge_indices"] = edge_indices
    return call_tool("chamfer_edges", arguments)


@mcp.tool()
def fillet_edges(
    entity_id: str,
    radius: float = 0.25,
    segments: int = 8,
    edge_indices: List[int] = None,
) -> str:
    """Round the edges of an entity. Omit edge_indices to fillet every edge."""
    arguments: Dict[str, Any] = {
        "entity_id": entity_id,
        "radius": radius,
        "segments": segments,
    }
    if edge_indices is not None:
        arguments["edge_indices"] = edge_indices
    return call_tool("fillet_edges", arguments)


@mcp.tool()
def create_mortise_tenon(
    mortise_id: str,
    tenon_id: str,
    width: float = 1.0,
    height: float = 1.0,
    depth: float = 1.0,
    offset_x: float = 0.0,
    offset_y: float = 0.0,
    offset_z: float = 0.0,
) -> str:
    """Cut a mortise in one board and a matching tenon on another."""
    return call_tool(
        "create_mortise_tenon",
        {
            "mortise_id": mortise_id,
            "tenon_id": tenon_id,
            "width": width,
            "height": height,
            "depth": depth,
            "offset_x": offset_x,
            "offset_y": offset_y,
            "offset_z": offset_z,
        },
    )


@mcp.tool()
def create_dovetail(
    tail_id: str,
    pin_id: str,
    width: float = 1.0,
    height: float = 1.0,
    depth: float = 1.0,
    angle: float = 15.0,
    num_tails: int = 3,
    offset_x: float = 0.0,
    offset_y: float = 0.0,
    offset_z: float = 0.0,
) -> str:
    """Cut interlocking dovetail tails and pins between two boards."""
    return call_tool(
        "create_dovetail",
        {
            "tail_id": tail_id,
            "pin_id": pin_id,
            "width": width,
            "height": height,
            "depth": depth,
            "angle": angle,
            "num_tails": num_tails,
            "offset_x": offset_x,
            "offset_y": offset_y,
            "offset_z": offset_z,
        },
    )


@mcp.tool()
def create_finger_joint(
    board1_id: str,
    board2_id: str,
    width: float = 1.0,
    height: float = 1.0,
    depth: float = 1.0,
    num_fingers: int = 5,
    offset_x: float = 0.0,
    offset_y: float = 0.0,
    offset_z: float = 0.0,
) -> str:
    """Cut a finger (box) joint between two boards."""
    return call_tool(
        "create_finger_joint",
        {
            "board1_id": board1_id,
            "board2_id": board2_id,
            "width": width,
            "height": height,
            "depth": depth,
            "num_fingers": num_fingers,
            "offset_x": offset_x,
            "offset_y": offset_y,
            "offset_z": offset_z,
        },
    )


@mcp.tool()
def export_scene(format: str = "skp", width: int = 1920, height: int = 1080) -> str:
    """Export the model and return the path written.

    Formats: skp, obj, dae, stl, fbx, 3ds, wrl, xsi, kmz, png, jpg. width and
    height apply to image exports only. Some exporters are SketchUp Pro only,
    and say so instead of failing silently.
    """
    return call_tool("export_scene", {"format": format, "width": width, "height": height})


@mcp.tool()
def eval_ruby(code: str) -> str:
    """Run Ruby inside SketchUp and return the last expression, as a string.

    The cheapest way to build anything non-trivial: one call can create a whole
    assembly, and it is a single undo step. Local variables persist between
    calls, so you can keep a reference (e.g. `legs = ...`) and reuse it later
    instead of re-sending context. Output is truncated past
    SKETCHUP_MCP_MAX_CHARS, so return ids or counts rather than whole objects.
    """
    return call_tool("eval_ruby", {"code": code}, raw_text=True)


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
