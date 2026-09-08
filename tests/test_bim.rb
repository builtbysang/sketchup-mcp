# Unit tests for the BIM layer. No SketchUp needed.
$LOAD_PATH.unshift(File.expand_path("stubs", __dir__))
require 'sketchup'
require 'tmpdir'
require_relative '../su_mcp/su_mcp/bim/route'

failures = []
def check(failures, label, cond, detail = nil)
  if cond
    puts "  PASS  #{label}"
  else
    puts "  FAIL  #{label}#{detail ? " -> #{detail}" : ""}"
    failures << label
  end
end

model = Sketchup.active_model
R = SU_MCP::Bim::Route

puts "\n[1] a route's length is the sum of its segments"
# 3000mm east, then 2000mm up: 5000mm total, one turn.
route = R.create(model, [[0, 0, 0], [3000, 0, 0], [3000, 0, 2000]])
check(failures, "group created and named", route.name == "MEP Route", route.name)
check(failures, "two segments", R.segments(route).length == 2, R.segments(route).length)
check(failures, "5.00 m", R.metres(route) == 5.0, R.metres(route))
check(failures, "one turn", R.turns(route) == 1, R.turns(route))

puts "\n[2] a straight run has no turns"
straight = R.create(model, [[0, 0, 0], [1000, 0, 0], [2500, 0, 0]])
check(failures, "2.50 m", R.metres(straight) == 2.5, R.metres(straight))
check(failures, "no turns on a colinear run", R.turns(straight) == 0, R.turns(straight))

puts "\n[3] a route needs at least two points"
begin
  R.create(model, [[0, 0, 0]])
  check(failures, "one point rejected", false, "no raise")
rescue StandardError => e
  check(failures, "one point rejected", e.message.include?("two points"), e.message)
end

puts "\n[4] routes are found by name, not by guessing"
check(failures, "both routes listed", R.all(model).length == 2, R.all(model).length)

puts "\n#{failures.empty? ? "ALL BIM CHECKS PASSED" : "FAILED: #{failures.join(', ')}"}"
exit(failures.empty? ? 0 : 1)
