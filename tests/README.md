# Tests

Three suites, in increasing coverage. None of them needs SketchUp installed.

```bash
ruby tests/test_extension.rb      # extension only: socket loop, dispatch, undo wrapping
python3 tests/test_transport.py   # server.py only: framing, id matching, retry policy
.venv/bin/python tests/test_end_to_end.py   # the whole stack
```

`test_extension.rb` loads `su_mcp/su_mcp/main.rb` against a fake SketchUp API
(`tests/stubs/sketchup.rb`) and drives it over a real TCP socket.

`test_transport.py` runs `server.py`'s socket layer against a fake extension.

`test_end_to_end.py` wires a real MCP client through stdio to the real
`server.py`, which talks over TCP to the real extension running on the stub API
— only SketchUp itself is faked. `tests/fake_sketchup_host.rb` is that host; the
suite starts and stops it on a free port by itself. It needs the venv:

```bash
uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python -e .
```
