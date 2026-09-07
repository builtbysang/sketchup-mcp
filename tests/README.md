# Tests

No SketchUp and no MCP client needed — both suites stub the far side.

```bash
ruby tests/test_extension.rb    # extension: socket loop, dispatch, undo wrapping
python3 tests/test_transport.py # server.py: framing, id matching, retry policy
```

`test_extension.rb` loads `su_mcp/su_mcp/main.rb` against a fake SketchUp API in
`tests/stubs/sketchup.rb` and drives it over a real TCP socket.
`test_transport.py` runs `server.py`'s socket layer against a fake extension.
