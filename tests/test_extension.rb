# Loads main.rb against a stub SketchUp API (tests/stubs/sketchup.rb).
$LOAD_PATH.unshift(File.expand_path("stubs", __dir__))
require 'sketchup'
require 'socket'
require 'json'

PORT = 19876
ENV['SKETCHUP_MCP_PORT'] = PORT.to_s

load File.expand_path("../su_mcp/su_mcp/main.rb", __dir__)

# Drive the same instance the menu commands close over, through the menu.
server = SU_MCP.instance_variable_get(:@server)
UI.menu("Plugins")["Start Server"].invoke

failures = []
def check(failures, label, cond, detail = nil)
  if cond
    puts "  PASS  #{label}"
  else
    puts "  FAIL  #{label}#{detail ? " -> #{detail}" : ""}"
    failures << label
  end
end

pump = lambda { |n = 12| n.times { UI.tick!; sleep 0.01 } }

sock = TCPSocket.new('127.0.0.1', PORT)
pump.call

send_req = lambda do |hash|
  sock.write(hash.to_json + "\n")
  deadline = Time.now + 3
  buf = +""
  while Time.now < deadline
    UI.tick!
    begin
      buf << sock.read_nonblock(65_536)
    rescue IO::WaitReadable, Errno::EAGAIN
      sleep 0.01
      next
    end
    break if buf.include?("\n")
  end
  JSON.parse(buf.split("\n").first.to_s)
end

puts "\n[1] ping over a live connection"
r = send_req.call({ "jsonrpc" => "2.0", "method" => "ping", "params" => {}, "id" => 1 })
check(failures, "ping answers with matching id", r["id"] == 1 && r["result"], r.inspect)

puts "\n[2] connection stays open for a second request (was closed after each before)"
r = send_req.call({ "jsonrpc" => "2.0", "method" => "tools/call",
                    "params" => { "name" => "create_component",
                                  "arguments" => { "type" => "cube", "position" => [0,0,0],
                                                   "dimensions" => [2,2,2] } }, "id" => 2 })
cube_id = r.dig("result", "resourceId")
check(failures, "create_component on the same socket", r["id"] == 2 && cube_id.is_a?(Integer), r.inspect)

ops = Sketchup.active_model.operations
check(failures, "wrapped in start_operation/commit_operation",
      ops.include?([:start, "MCP: create_component"]) && ops.include?([:commit]), ops.inspect)

puts "\n[3] get_scene_info payload survives (old code dropped everything but :result)"
r = send_req.call({ "jsonrpc" => "2.0", "method" => "tools/call",
                    "params" => { "name" => "get_scene_info", "arguments" => {} }, "id" => 3 })
text = r.dig("result", "content", 0, "text").to_s
info = (JSON.parse(text) rescue {})
check(failures, "scene info returns structured data", info["entity_count"].is_a?(Integer) && info["units"] == "inches", text[0, 160])
check(failures, "summary mode omits per-entity bounds", !text.include?("bounds\":{\"min") || !info["entities"].to_a.first.to_h.key?("bounds"), text[0,160])

puts "\n[4] get_selection keeps its entity list"
Sketchup.active_model.selection.replace(Sketchup.active_model.entities.to_a)
r = send_req.call({ "jsonrpc" => "2.0", "method" => "tools/call",
                    "params" => { "name" => "get_selection", "arguments" => {} }, "id" => 4 })
sel = JSON.parse(r.dig("result", "content", 0, "text")) rescue {}
check(failures, "selection entities reach the client", sel["entities"].is_a?(Array) && !sel["entities"].empty?, r.inspect)

puts "\n[5] batch create is one operation, N shapes"
before = Sketchup.active_model.operations.length
r = send_req.call({ "jsonrpc" => "2.0", "method" => "tools/call",
                    "params" => { "name" => "create_components",
                                  "arguments" => { "components" => [
                                    { "type" => "cube", "position" => [0,0,0], "dimensions" => [1,1,1] },
                                    { "type" => "cube", "position" => [2,0,0], "dimensions" => [1,1,1] },
                                    { "type" => "cube", "position" => [4,0,0], "dimensions" => [1,1,1] }] } }, "id" => 5 })
batch = JSON.parse(r.dig("result", "content", 0, "text")) rescue {}
added = Sketchup.active_model.operations.length - before
check(failures, "3 shapes in one call", batch["count"] == 3 && batch["ids"].to_a.length == 3, r.inspect)
check(failures, "3 shapes cost one undo step", added == 2, "operations added: #{added}")

puts "\n[6] eval_ruby keeps locals between calls"
send_req.call({ "jsonrpc" => "2.0", "method" => "tools/call",
                "params" => { "name" => "eval_ruby", "arguments" => { "code" => "shelf_count = 7" } }, "id" => 6 })
r = send_req.call({ "jsonrpc" => "2.0", "method" => "tools/call",
                    "params" => { "name" => "eval_ruby", "arguments" => { "code" => "shelf_count * 2" } }, "id" => 7 })
check(failures, "local variable persists across calls", r.dig("result", "content", 0, "text") == "14", r.inspect)

puts "\n[7] oversized eval_ruby output is clamped"
r = send_req.call({ "jsonrpc" => "2.0", "method" => "tools/call",
                    "params" => { "name" => "eval_ruby", "arguments" => { "code" => "'x' * 50000" } }, "id" => 8 })
out = r.dig("result", "content", 0, "text").to_s
check(failures, "output clamped under budget", out.length < 4300 && out.include?("truncated"), "len=#{out.length}")

puts "\n[8] a request split across two TCP writes is reassembled"
part = { "jsonrpc" => "2.0", "method" => "ping", "params" => {}, "id" => 9 }.to_json
sock.write(part[0, 12]); pump.call(5)
sock.write(part[12..] + "\n")
deadline = Time.now + 3
buf = +""
while Time.now < deadline
  UI.tick!
  begin; buf << sock.read_nonblock(65_536); rescue IO::WaitReadable, Errno::EAGAIN; sleep 0.01; next; end
  break if buf.include?("\n")
end
check(failures, "split request handled without blocking", JSON.parse(buf.split("\n").first.to_s)["id"] == 9, buf.inspect)

puts "\n[9] a connected-but-silent client does not stall the loop"
idle = TCPSocket.new('127.0.0.1', PORT)
t0 = Time.now
pump.call(10)
check(failures, "idle client costs no wall time", (Time.now - t0) < 1.0, "#{Time.now - t0}s")
r = send_req.call({ "jsonrpc" => "2.0", "method" => "ping", "params" => {}, "id" => 10 })
check(failures, "other clients still served", r["id"] == 10, r.inspect)
idle.close

puts "\n[10] failing tool aborts the operation instead of leaving partial geometry"
before = Sketchup.active_model.operations.length
r = send_req.call({ "jsonrpc" => "2.0", "method" => "tools/call",
                    "params" => { "name" => "eval_ruby", "arguments" => { "code" => "raise 'boom'" } }, "id" => 11 })
tail = Sketchup.active_model.operations[before..]
check(failures, "error returns JSON-RPC error", !r["error"].nil?, r.inspect)
check(failures, "abort_operation called", tail.include?([:abort]), tail.inspect)

puts "\n[11] unknown tool"
r = send_req.call({ "jsonrpc" => "2.0", "method" => "tools/call",
                    "params" => { "name" => "nope", "arguments" => {} }, "id" => 12 })
check(failures, "unknown tool -> error, no crash", r["error"] && r["error"]["message"].include?("Unknown tool"), r.inspect)

puts "\n[12] menu reflects state without opening a dialog"
menu = UI.menu("Plugins")
start_item = menu["Start Server"]
stop_item  = menu["Stop Server"]
auto_item  = menu["Start on Launch"]
check(failures, "menu items registered", [start_item, stop_item, auto_item].none?(&:nil?), menu.items.map(&:name).inspect)
check(failures, "Start greys out while running", start_item.validate == MF_GRAYED, start_item.validate)
check(failures, "Stop is available while running", stop_item.validate == MF_ENABLED, stop_item.validate)

puts "\n[13] autostart preference persists and drives the checkmark"
check(failures, "off by default", !SU_MCP.autostart? && auto_item.validate == MF_UNCHECKED, auto_item.validate)
auto_item.invoke
check(failures, "toggles on and is remembered", SU_MCP.autostart? && auto_item.validate == MF_CHECKED, auto_item.validate)
check(failures, "written to SketchUp defaults", Sketchup.read_default("SU_MCP", "autostart", false) == true)
auto_item.invoke
check(failures, "toggles back off", !SU_MCP.autostart?, auto_item.validate)

ENV['SKETCHUP_MCP_AUTOSTART'] = '1'
check(failures, "env var forces autostart on", SU_MCP.autostart?)
ENV.delete('SKETCHUP_MCP_AUTOSTART')

puts "\n[14] toolbar shares the menu's commands rather than cloning them"
toolbar = UI::Toolbar["MCP Server"]
check(failures, "toolbar registered and restored", !toolbar.nil? && toolbar.restored?)
check(failures, "three buttons", toolbar.items.length == 3, toolbar.items.map(&:name).inspect)
%w[Start\ Server Stop\ Server].each do |name|
  check(failures, "#{name}: one object, two surfaces", toolbar[name].equal?(menu[name]))
end
check(failures, "Panel button opens the panel, and sits in the menu too", !menu["Panel"].nil? && !toolbar["Panel"].nil?)
missing = toolbar.items.flat_map { |c| [c.large_icon, c.small_icon] }.reject { |p| File.file?(p.to_s) }
check(failures, "every icon file present", missing.empty?, missing.inspect)
check(failures, "buttons carry tooltips", toolbar.items.none? { |c| c.tooltip.to_s.empty? })

puts "\n[15] panel reads state from Ruby and drives the server"
panel = SU_MCP.show_panel
check(failures, "panel loads the shipped html", File.file?(panel.file.to_s) && panel.file.end_with?("panel.html"))
s = panel.last_state
check(failures, "state pushed on ready", !s.nil? && s["running"] == true, s.inspect)
check(failures, "address comes from the server, not the page", s && s["port"] == PORT && !s["host"].to_s.empty?, s.inspect)

panel.invoke("stop")
check(failures, "Stop in the panel stops the server", !server.running? && panel.last_state["running"] == false)
panel.invoke("start")
check(failures, "Start in the panel starts it again", server.running? && panel.last_state["running"] == true)

panel.invoke("set_autostart", true)
check(failures, "checkbox writes the preference", SU_MCP.autostart? && panel.last_state["autostart"] == true)
panel.invoke("set_autostart", false)
check(failures, "and clears it", !SU_MCP.autostart? && panel.last_state["autostart"] == false)

menu["Stop Server"].invoke
check(failures, "menu action refreshes the panel", panel.last_state["running"] == false)
menu["Start Server"].invoke

check(failures, "opening twice fronts the same panel", SU_MCP.show_panel.equal?(panel) && panel.fronted?)

busy = SU_MCP::Server.new(port: PORT)
busy.start
check(failures, "a taken port becomes a readable error, not silence", !busy.last_error.to_s.empty?, busy.last_error.inspect)
check(failures, "and the failed server is not left half-open", !busy.running?)

sock.close
UI.menu("Plugins")["Stop Server"].invoke

check(failures, "Start becomes available once stopped", start_item.validate == MF_ENABLED, start_item.validate)
check(failures, "Stop greys out once stopped", stop_item.validate == MF_GRAYED, stop_item.validate)

puts "\n#{failures.empty? ? "ALL RUBY CHECKS PASSED" : "FAILED: #{failures.join(', ')}"}"
exit(failures.empty? ? 0 : 1)
