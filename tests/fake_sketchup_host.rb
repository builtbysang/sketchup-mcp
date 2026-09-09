# Runs the real extension (su_mcp/su_mcp/main.rb) against the stub SketchUp API
# and pumps its UI timer, so the whole stack can be exercised without SketchUp.
repo = ARGV[0]
$LOAD_PATH.unshift(File.join(repo, "tests", "stubs"))
require 'sketchup'
load File.join(repo, "su_mcp", "su_mcp", "main.rb")

# No menu item starts the server any more — the window that owns it does.
SU_MCP.open_dialog(:server).invoke("start")
$stderr.puts "fake host up on port #{ENV['SKETCHUP_MCP_PORT']}"
$stderr.flush
trap("INT") { exit 0 }
trap("TERM") { exit 0 }
loop { UI.tick!; sleep 0.02 }
