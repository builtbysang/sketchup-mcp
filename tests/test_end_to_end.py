"""Full stack: real MCP client -> stdio -> server.py -> TCP -> real main.rb.

Only the SketchUp API itself is stubbed. Needs the venv built by
`uv venv --python 3.12 .venv && uv pip install -e .`, and `ruby` on PATH.
"""
import asyncio, contextlib, json, os, pathlib, socket, subprocess, sys, time
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

REPO = str(pathlib.Path(__file__).resolve().parent.parent)
fails = []


def free_port():
    with contextlib.closing(socket.socket()) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@contextlib.contextmanager
def fake_sketchup(port):
    """The real extension, loaded against the stub SketchUp API."""
    proc = subprocess.Popen(
        ["ruby", f"{REPO}/tests/fake_sketchup_host.rb", REPO],
        env=dict(os.environ, SKETCHUP_MCP_PORT=str(port)),
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    try:
        deadline = time.time() + 10
        while time.time() < deadline:
            with contextlib.closing(socket.socket()) as probe:
                if probe.connect_ex(("127.0.0.1", port)) == 0:
                    break
            if proc.poll() is not None:
                raise RuntimeError(f"fake host died:\n{proc.stdout.read()}")
            time.sleep(0.1)
        else:
            raise RuntimeError("fake host never started listening")
        yield
    finally:
        proc.terminate()
        with contextlib.suppress(subprocess.TimeoutExpired):
            proc.wait(timeout=5)

def check(label, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + label + ("" if cond else f" -> {detail}"))
    if not cond: fails.append(label)

def payload(result):
    return json.loads(result.content[0].text)

async def main(port):
    env = dict(os.environ, SKETCHUP_MCP_PORT=str(port), SKETCHUP_MCP_TIMEOUT="15")
    params = StdioServerParameters(command=f"{REPO}/.venv/bin/sketchup-mcp", args=[], env=env)

    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            init = await session.initialize()
            print(f"\n[1] handshake with {init.serverInfo.name} {init.serverInfo.version}")
            check("initialize succeeded", init.serverInfo.name == "SketchupMCP", init.serverInfo)

            tools = (await session.list_tools()).tools
            names = sorted(t.name for t in tools)
            print(f"\n[2] tool discovery ({len(names)} tools)")
            check("all tools advertised", len(names) == 21, names)
            check("previously unreachable tools exposed",
                  {"boolean_operation", "chamfer_edges", "fillet_edges",
                   "get_scene_info", "create_components"} <= set(names), names)
            schema = next(t for t in tools if t.name == "create_components").inputSchema
            check("batch tool has a usable schema", "components" in schema["properties"], schema)

            print("\n[3] get_scene_info on an empty model")
            info = payload(await session.call_tool("get_scene_info", {}))
            check("structured scene info", info["success"] and info["units"] == "inches", info)
            check("starts empty", info["entity_count"] == 0, info)

            print("\n[4] create_component returns a real entity id")
            made = payload(await session.call_tool(
                "create_component",
                {"type": "cube", "position": [0, 0, 0], "dimensions": [24, 12, 1]}))
            check("id returned", isinstance(made.get("id"), int), made)

            print("\n[5] create_components builds a batch in one call")
            batch = payload(await session.call_tool("create_components", {"components": [
                {"type": "cube", "position": [0, 0, 0], "dimensions": [2, 2, 30]},
                {"type": "cube", "position": [22, 0, 0], "dimensions": [2, 2, 30]},
                {"type": "cube", "position": [0, 10, 0], "dimensions": [2, 2, 30]},
                {"type": "cube", "position": [22, 10, 0], "dimensions": [2, 2, 30]},
            ]}))
            check("four legs, four ids", batch.get("count") == 4 and len(batch["ids"]) == 4, batch)

            print("\n[6] the model reflects everything that was built")
            info = payload(await session.call_tool("get_scene_info", {"limit": 10}))
            check("5 groups now present", info["group_count"] == 5, info)
            check("summary omits bounds by default", "bounds" not in info["entities"][0], info["entities"][0])
            detailed = payload(await session.call_tool("get_scene_info", {"detail": True}))
            check("detail=True adds bounds", "bounds" in detailed["entities"][0], detailed["entities"][0])

            print("\n[7] eval_ruby round trip, and state kept between calls")
            first = payload(await session.call_tool("eval_ruby", {"code": "shelf_height = 30"}))
            check("returns the expression value", first["result"] == "30", first)
            second = payload(await session.call_tool("eval_ruby", {"code": "shelf_height + 6"}))
            check("local survived into the next call", second["result"] == "36", second)

            print("\n[8] selection travels back intact (the bug that returned 'Success')")
            await session.call_tool("eval_ruby", {"code":
                "m = Sketchup.active_model; m.selection.replace(m.entities.to_a[0,2]); m.selection.length"})
            sel = payload(await session.call_tool("get_selection", {}))
            check("entities, not a bare string", isinstance(sel.get("entities"), list) and len(sel["entities"]) == 2, sel)

            print("\n[9] failures come back as errors, not silent success")
            bad = payload(await session.call_tool("eval_ruby", {"code": "raise 'kaboom'"}))
            check("error surfaced with its message", bad["success"] is False and "kaboom" in bad["error"], bad)
            unknown = payload(await session.call_tool("delete_component", {"id": "99999"}))
            check("deleting a missing id fails cleanly", unknown["success"] is False, unknown)

            print("\n[10] oversized output is clamped instead of flooding the client")
            big = payload(await session.call_tool("eval_ruby", {"code": "'z' * 200000"}))
            check("clamped", len(json.dumps(big)) < 6000, len(json.dumps(big)))

            print("\n[11] export writes a real file and reports the path")
            exported = payload(await session.call_tool("export_scene", {"format": "skp"}))
            check("path returned and file exists",
                  exported["success"] and os.path.exists(exported["path"]), exported)

            print("\n[12] MEP: a route, a label and a schedule over the wire")
            r = payload(await session.call_tool(
                "mep_declare_storeys",
                {"storeys": [{"name": "L1", "elevation_mm": 0}]}))
            check("storeys declared", r["success"], r)

            r = payload(await session.call_tool("mep_create_route", {
                "points_mm": [[0, 0, 0], [4000, 0, 0]],
                "system": "cold_water", "diameter_mm": 50, "material": "PPR"}))
            check("route created and measured", r["metres"] == 4.0, r)

            r = payload(await session.call_tool(
                "mep_create_route", {"points_mm": [[0, 1000, 0], [3000, 1000, 0]]}))
            check("an unlabelled route is allowed", r["success"], r)

            sched = payload(await session.call_tool("mep_schedule", {}))
            check("labelled metres reported",
                  any(row["metres"] == 4.0 for row in sched["rows"]), sched)
            check("unlabelled surfaced", sched["unlabelled"]["routes"] == 1, sched["unlabelled"])

            orphans = payload(await session.call_tool("mep_unlabelled", {}))
            check("unlabelled route listed with an id",
                  len(orphans["routes"]) == 1 and orphans["routes"][0]["id"], orphans)

            r = payload(await session.call_tool("mep_label", {
                "id": str(orphans["routes"][0]["id"]), "system": "rainwater",
                "diameter_mm": 75, "material": "PVC"}))
            check("labelling later works", r["label"]["diameter_mm"] == 75, r)

            sched = payload(await session.call_tool("mep_schedule", {}))
            check("nothing unlabelled now", sched["unlabelled"]["routes"] == 0, sched["unlabelled"])

            out = payload(await session.call_tool("mep_export_schedule", {"path": ""}))
            check("CSV written where it says", os.path.exists(out["path"]), out)

    print("\n" + ("END-TO-END PASSED" if not fails else "FAILED: " + ", ".join(fails)))
    return 1 if fails else 0

PORT = free_port()
with fake_sketchup(PORT):
    sys.exit(asyncio.run(main(PORT)))
