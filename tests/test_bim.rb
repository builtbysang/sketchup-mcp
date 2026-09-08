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

require_relative '../su_mcp/su_mcp/bim/label'
L = SU_MCP::Bim::Label

puts "\n[5] a label rides on IFC vocabulary and reads back whole"
L.write(route, system: "domestic_cold_water", diameter_mm: 50, material: "PPR")
back = L.read(route)
check(failures, "reads back", back[:system] == "domestic_cold_water" && back[:diameter_mm] == 50, back.inspect)
check(failures, "defaults to a pipe segment", back[:ifc_class] == "IfcPipeSegment", back[:ifc_class])
check(failures, "IFC class also written to the classifier",
      route.definition.get_classification_value(["IFC 4", "IfcPipeSegment"]) == "IfcPipeSegment",
      route.definition.get_classification_value(["IFC 4", "IfcPipeSegment"]).inspect)
check(failures, "labelled? true", L.labelled?(route))

puts "\n[6] an unlabelled route says so instead of returning zeros"
check(failures, "read is nil, not a blank hash", L.read(straight).nil?, L.read(straight).inspect)
check(failures, "labelled? false", !L.labelled?(straight))

puts "\n[7] diameter is a free millimetre value, not a whitelist"
odd = R.create(model, [[0, 0, 0], [1000, 0, 0]])
L.write(odd, system: "rainwater", diameter_mm: 47, material: "PVC")
check(failures, "47mm accepted", L.read(odd)[:diameter_mm] == 47, L.read(odd).inspect)

require_relative '../su_mcp/su_mcp/bim/storey'
S = SU_MCP::Bim::Storey

puts "\n[8] storeys are declared once and inferred from height"
S.declare(model, [{ "name" => "L2", "elevation_mm" => 3200 }, { "name" => "L1", "elevation_mm" => 0 }])
check(failures, "sorted by elevation", S.all(model).map { |s| s["name"] } == %w[L1 L2], S.all(model).inspect)
check(failures, "at floor level", S.of(model, 0) == "L1", S.of(model, 0))
check(failures, "just under L2", S.of(model, 3000 / 25.4) == "L1", S.of(model, 3000 / 25.4))
check(failures, "at L2", S.of(model, 3200 / 25.4) == "L2", S.of(model, 3200 / 25.4))
check(failures, "below the lowest storey is unassigned", S.of(model, -100) == "unassigned", S.of(model, -100))
check(failures, "route takes the storey of its lowest point", S.of_route(model, route) == "L1", S.of_route(model, route))

# A riser crossing a storey boundary belongs to the storey it starts on, not
# both: a pipe counted twice is worse than a pipe on the wrong floor.
riser = R.create(model, [[0, 0, 2000], [0, 0, 5000]])
L.write(riser, system: "cold_water", diameter_mm: 32, material: "PPR")
check(failures, "a riser is not split across storeys", S.of_route(model, riser) == "L1", S.of_route(model, riser))

puts "\n[9] with no storeys declared nothing is invented"
bare = Sketchup::Model.new
check(failures, "unassigned, not L1", S.of(bare, 0) == "unassigned", S.of(bare, 0))

require_relative '../su_mcp/su_mcp/bim/schedule'
SCH = SU_MCP::Bim::Schedule

puts "\n[10] the schedule groups by system, diameter and storey"
model2 = Sketchup::Model.new
S.declare(model2, [{ "name" => "L1", "elevation_mm" => 0 }])
a = R.create(model2, [[0, 0, 0], [4000, 0, 0]])                  # 4.00 m
b = R.create(model2, [[0, 500, 0], [2000, 500, 0]])              # 2.00 m, same system+size
c = R.create(model2, [[0, 0, 0], [1000, 0, 0], [1000, 0, 1000]]) # 2.00 m, 1 turn, other size
L.write(a, system: "cold_water", diameter_mm: 50, material: "PPR")
L.write(b, system: "cold_water", diameter_mm: 50, material: "PPR")
L.write(c, system: "cold_water", diameter_mm: 25, material: "PPR")
orphan = R.create(model2, [[0, 0, 0], [3000, 0, 0]])             # 3.00 m, no label

s = SCH.build(model2)
row50 = s[:rows].find { |r| r["diameter_mm"] == 50 }
row25 = s[:rows].find { |r| r["diameter_mm"] == 25 }
check(failures, "same system+size merge into one row", row50["routes"] == 2, row50.inspect)
check(failures, "metres add up", row50["metres"] == 6.0, row50["metres"])
check(failures, "joints counted", row25["joints"] == 1, row25.inspect)
check(failures, "storey carried", row50["storey"] == "L1", row50["storey"])
check(failures, "unlabelled surfaced, not skipped", s[:unlabelled]["routes"] == 1 && s[:unlabelled]["metres"] == 3.0, s[:unlabelled].inspect)
check(failures, "total includes the unlabelled metres", s[:total_metres] == 11.0, s[:total_metres])
check(failures, "rows sorted by diameter", s[:rows].map { |r| r["diameter_mm"] } == [25, 50], s[:rows].map { |r| r["diameter_mm"] }.inspect)

puts "\n[11] an edited route is re-measured, never remembered"
before = SCH.build(model2)[:total_metres]
a.entities.add_edges([Geom::Point3d.new(4000 / 25.4, 0, 0), Geom::Point3d.new(6000 / 25.4, 0, 0)])
after = SCH.build(model2)[:total_metres]
check(failures, "length changes when the model changes", after == (before + 2.0).round(2), "#{before} -> #{after}")

puts "\n#{failures.empty? ? "ALL BIM CHECKS PASSED" : "FAILED: #{failures.join(', ')}"}"
exit(failures.empty? ? 0 : 1)
