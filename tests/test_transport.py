"""Drive server.py's socket layer against a fake su_mcp extension."""
import json, socket, sys, threading, time, types, os, pathlib

# --- stub just enough of mcp.server.fastmcp to import server.py ---------
fastmcp = types.ModuleType("mcp.server.fastmcp")
class _FakeMCP:
    def __init__(self, *a, **k): self.tools = {}
    def tool(self, *a, **k):
        def deco(fn):
            self.tools[fn.__name__] = fn
            return fn
        return deco
    def run(self): pass
class _Ctx: pass
fastmcp.FastMCP = _FakeMCP
fastmcp.Context = _Ctx
mcp_pkg = types.ModuleType("mcp"); server_pkg = types.ModuleType("mcp.server")
sys.modules.update({"mcp": mcp_pkg, "mcp.server": server_pkg, "mcp.server.fastmcp": fastmcp})

PORT = 19877
os.environ["SKETCHUP_MCP_PORT"] = str(PORT)
os.environ["SKETCHUP_MCP_TIMEOUT"] = "2"
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "src"))
import sketchup_mcp.server as srv

# --- fake extension: persistent, newline framed, echoes the request id ---
class FakeExtension(threading.Thread):
    daemon = True
    def __init__(self):
        super().__init__()
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", PORT))
        self.sock.listen(5)
        self.seen = []
        self.mode = "normal"
        self.stop_flag = False
    def run(self):
        while not self.stop_flag:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self.serve, args=(conn,), daemon=True).start()
    def serve(self, conn):
        buf = b""
        while not self.stop_flag:
            try:
                chunk = conn.recv(65536)
            except OSError:
                return
            if not chunk:
                return
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if not line.strip():
                    continue
                req = json.loads(line)
                self.seen.append(req)
                name = req["params"]["name"]
                if self.mode == "slow":
                    time.sleep(5)
                    continue
                if self.mode == "drop":
                    conn.close(); return
                if name == "boom":
                    resp = {"jsonrpc": "2.0", "error": {"code": -32603, "message": "Ruby evaluation error: boom"}, "id": req["id"]}
                else:
                    if name == "eval_ruby":
                        text = "42"
                    elif name == "huge":
                        text = json.dumps({"blob": "x" * 20000})
                    else:
                        text = json.dumps({"entities": [{"id": 101, "type": "group"}]})
                    resp = {"jsonrpc": "2.0", "id": req["id"],
                            "result": {"content": [{"type": "text", "text": text}],
                                       "isError": False, "success": True, "resourceId": 101}}
                # split every response across two writes to exercise framing
                blob = (json.dumps(resp) + "\n").encode()
                conn.sendall(blob[:7]); time.sleep(0.01); conn.sendall(blob[7:])

fails = []
def check(label, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + label + ("" if cond else f" -> {detail}"))
    if not cond: fails.append(label)

ext = FakeExtension(); ext.start(); time.sleep(0.2)

print("\n[1] structured payload round trip")
out = json.loads(srv.call_tool("get_selection", {}))
check("entities survive the envelope", out.get("entities") == [{"id": 101, "type": "group"}], out)
check("resourceId folded in as id", out.get("id") == 101, out)

print("\n[2] eval_ruby keeps its text raw instead of guessing JSON")
out = json.loads(srv.call_tool("eval_ruby", {"code": "6*7"}, raw_text=True))
check("raw text preserved as a string", out.get("result") == "42", out)

print("\n[3] one persistent socket, ids increment and match")
before = len(ext.seen)
for _ in range(3):
    srv.call_tool("get_selection", {})
ids = [r["id"] for r in ext.seen[before:]]
check("3 calls reuse one connection", ids == sorted(ids) and len(set(ids)) == 3, ids)

print("\n[4] oversized results are clamped to the response budget")
out = json.loads(srv.call_tool("huge", {}))
check("truncated with a marker", out.get("truncated") is True and len(json.dumps(out)) < srv.MAX_CHARS + 200, list(out)[:5])

print("\n[5] extension errors become clean tool errors")
out = json.loads(srv.call_tool("boom", {}))
check("error surfaced, not raised", out == {"success": False, "error": "Ruby evaluation error: boom"}, out)

print("\n[6] a timeout must NOT resend the request (non-idempotent extension)")
ext.mode = "slow"
before = len(ext.seen)
t0 = time.time()
out = json.loads(srv.call_tool("get_selection", {}))
elapsed = time.time() - t0
sent = len(ext.seen) - before
check("request sent exactly once", sent == 1, f"sent {sent} times")
check("returns after the timeout, not later", 1.5 < elapsed < 4.5, f"{elapsed:.1f}s")
check("says it was not retried", "NOT resent" in out.get("error", ""), out)
ext.mode = "normal"

print("\n[7] a dropped connection reconnects on the next call")
ext.mode = "drop"
srv.call_tool("get_selection", {})       # server hangs up on this one
ext.mode = "normal"
out = json.loads(srv.call_tool("get_selection", {}))
check("next call succeeds after reconnect", out.get("success") is True, out)

print("\n[8] SketchUp not running gives an actionable message")
srv.get_sketchup_connection().close()
ext.stop_flag = True; ext.sock.close(); time.sleep(0.2)
out = json.loads(srv.call_tool("get_selection", {}))
check("names the fix", "Start Server" in out.get("error", "") and out["success"] is False, out)

print("\n" + ("ALL PYTHON CHECKS PASSED" if not fails else "FAILED: " + ", ".join(fails)))
sys.exit(1 if fails else 0)
