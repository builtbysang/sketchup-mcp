# Loads main.rb against a stub SketchUp API (tests/stubs/sketchup.rb).
$LOAD_PATH.unshift(File.expand_path("stubs", __dir__))
require 'sketchup'
require 'socket'
require 'json'
require 'tmpdir'
require 'fileutils'

PORT = 19876
ENV['SKETCHUP_MCP_PORT'] = PORT.to_s

load File.expand_path("../su_mcp/su_mcp/main.rb", __dir__)

# Drive the same instance the toolbar commands close over, through the window
# they open — there is no menu item that starts the server any more.
server = SU_MCP.instance_variable_get(:@server)
SU_MCP.open_dialog(:server).invoke("start")

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

puts "\n[12] one toolbar button per window, shared with the menu"
menu    = UI.menu("Plugins")
toolbar = UI::Toolbar["MCP Server"]
titles  = ["Máy chủ MCP", "Thống kê ống", "Cài đặt"]
check(failures, "toolbar registered and restored", !toolbar.nil? && toolbar.restored?)
check(failures, "three buttons, one per window", toolbar.items.length == 3, toolbar.items.map(&:name).inspect)
titles.each do |title|
  check(failures, "#{title}: one object, two surfaces",
        !menu[title].nil? && toolbar[title].equal?(menu[title]), menu.items.map(&:name).inspect)
end
missing = toolbar.items.flat_map { |c| [c.large_icon, c.small_icon] }.reject { |p| File.file?(p.to_s) }
check(failures, "every icon file present", missing.empty?, missing.inspect)
check(failures, "buttons carry tooltips", toolbar.items.none? { |c| c.tooltip.to_s.empty? })
check(failures, "no button starts the server directly any more",
      menu["Start Server"].nil? && menu["Stop Server"].nil?, menu.items.map(&:name).inspect)
check(failures, "camera and scenes are not this plugin's job",
      menu["Render"].nil? && menu["Cảnh & camera"].nil?, menu.items.map(&:name).inspect)

puts "\n[13] the server window reads state from Ruby and drives the server"
panel = SU_MCP.open_dialog(:server)
check(failures, "loads the shipped html", File.file?(panel.file.to_s) && panel.file.end_with?("server.html"))
st = panel.last_state
check(failures, "state pushed on ready", !st.nil? && st["running"] == true, st.inspect)
check(failures, "address comes from the server, not the page",
      st && st["port"] == PORT && !st["host"].to_s.empty?, st.inspect)
check(failures, "the open socket is counted", st["clients"].to_i >= 1, st["clients"].inspect)
check(failures, "the window can read the log the console would have shown",
      st["log"].is_a?(Array) && !st["log"].empty? && st["log"].last.key?("text"), st["log"].inspect)

panel.invoke("stop")
check(failures, "Stop in the window stops the server", !server.running? && panel.last_state["running"] == false)
panel.invoke("start")
check(failures, "Start in the window starts it again", server.running? && panel.last_state["running"] == true)
check(failures, "opening twice fronts the same window",
      SU_MCP.open_dialog(:server).equal?(panel) && panel.fronted?)

busy = SU_MCP::Server.new(port: PORT)
busy.start
check(failures, "a taken port becomes a readable error, not silence", !busy.last_error.to_s.empty?, busy.last_error.inspect)
check(failures, "and the failed server is not left half-open", !busy.running?)

puts "\n[14] the settings window owns the preferences"
settings = SU_MCP.open_dialog(:settings)
check(failures, "loads the shipped html", settings.file.to_s.end_with?("settings.html"))
sset = settings.last_state
check(failures, "every setting arrives with a value",
      %w[autostart port].all? { |k| sset.key?(k) }, sset.keys.inspect)

check(failures, "autostart off by default", !SU_MCP.autostart?)
settings.invoke("set", "autostart", true)
check(failures, "toggled on and remembered",
      SU_MCP.autostart? && settings.last_state["autostart"] == true)
check(failures, "written to SketchUp defaults", Sketchup.read_default("SU_MCP", "autostart", false) == true)
settings.invoke("set", "autostart", false)
check(failures, "and cleared", !SU_MCP.autostart? && settings.last_state["autostart"] == false)

ENV['SKETCHUP_MCP_AUTOSTART'] = '1'
check(failures, "env var forces autostart on", SU_MCP.autostart?)
ENV.delete('SKETCHUP_MCP_AUTOSTART')

settings.invoke("set", "not_a_setting", 1)
check(failures, "an unknown key is refused, not stored",
      !settings.last_state["error"].to_s.empty?, settings.last_state["error"].inspect)

settings.invoke("set", "port", 19999)
check(failures, "port cannot move while the server is bound",
      !settings.last_state["error"].to_s.empty? && server.port == PORT,
      [settings.last_state["error"], server.port].inspect)
check(failures, "and the stored port is left alone too", SU_MCP::Prefs.get("port") != 19999,
      SU_MCP::Prefs.get("port").inspect)

puts "\n[15] the schedule window measures and exports"
schedule = SU_MCP.open_dialog(:schedule)
check(failures, "loads the shipped html", schedule.file.to_s.end_with?("schedule.html"))
check(failures, "nothing is measured until asked", schedule.last_state["schedule"].nil?)
schedule.invoke("measure")
sched = schedule.last_state["schedule"]
check(failures, "schedule pushed to the window", !sched.nil?, schedule.last_state.keys.inspect)
check(failures, "unlabelled block always present", sched["unlabelled"].is_a?(Hash), sched.inspect)

out = File.join(Dir.tmpdir, "panel_schedule.csv")
File.delete(out) if File.exist?(out)
schedule.invoke("export", out)
check(failures, "export writes the file the window asked for", File.exist?(out))
check(failures, "the window is told where it landed", schedule.last_state["exported"] == out,
      schedule.last_state["exported"].inspect)

sock.close
panel.invoke("stop")
check(failures, "the server window reflects the stop", panel.last_state["running"] == false)

settings.invoke("set", "port", 19999)
check(failures, "the port moves once nothing is bound",
      server.port == 19999 && SU_MCP::Prefs.get("port") == 19999,
      [server.port, SU_MCP::Prefs.get("port")].inspect)

puts "\n#{failures.empty? ? "ALL RUBY CHECKS PASSED" : "FAILED: #{failures.join(', ')}"}"
exit(failures.empty? ? 0 : 1)
