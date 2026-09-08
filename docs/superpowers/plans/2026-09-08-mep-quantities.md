# MEP Quantities Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a per-storey, per-diameter pipe quantity schedule from a SketchUp model and write it as CSV.

**Architecture:** A centreline route (a Group of edges) is the only source of length. Labels — IFC class plus system, nominal diameter and material — live on the route group's ComponentDefinition, using the IFC schemas already loaded in this Pro install plus one side dictionary for what IFC lacks. Storeys are declared once as name+elevation on the model and inferred from a route's Z. The schedule groups routes and reports metres; a pipe solid can be extruded for looks and is never measured.

**Tech Stack:** SketchUp 2024 Pro Ruby API (extension side), Python 3.11 + `mcp[cli]` 1.x FastMCP (client side), plain Ruby unit tests against `tests/stubs/sketchup.rb`.

## Global Constraints

- SketchUp's internal length unit is **inches**. All public inputs are **millimetres**; all reported lengths are **metres to 2 decimals**. Convert with `MM_PER_INCH = 25.4` and `metres = inches * 0.0254` — no other conversion constants anywhere.
- **Lengths are never cached on an entity.** Every schedule run re-reads geometry, because the owner can drag a route in SketchUp between runs.
- **An unlabelled route must appear in the schedule as its own row**, never be skipped. Missing is worse than wrong.
- Nominal diameter is a free integer in millimetres. Suggested list (20, 25, 32, 40, 50, 63, 75, 90, 110) is advisory copy only — never a validation whitelist.
- New Ruby lives in `su_mcp/su_mcp/bim/*.rb`, one file per unit, required from `main.rb`. `main.rb` is already ~1,100 lines; do not grow it beyond dispatch entries.
- Every tool that writes to the model must be added to `MUTATING_TOOLS` in `main.rb`, or its changes will not land as one undo step.
- Tests must pass with no SketchUp running: `ruby tests/test_bim.rb`.

---

### Task 1: Route — geometry in, metres out

**Files:**
- Create: `su_mcp/su_mcp/bim/route.rb`
- Create: `tests/test_bim.rb`
- Modify: `tests/stubs/sketchup.rb` (add `Geom::Point3d`, `Sketchup::Edge`, `Entities#add_edges`, `Group#definition`)
- Modify: `su_mcp/su_mcp/main.rb` (require the new file)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `SU_MCP::Bim::Route.create(model, points_mm)` → `Sketchup::Group` named `"MEP Route"`
  - `SU_MCP::Bim::Route.segments(group)` → `Array<Array(Geom::Point3d, Geom::Point3d)>` in inches
  - `SU_MCP::Bim::Route.length_inches(group)` → `Float`
  - `SU_MCP::Bim::Route.metres(group)` → `Float` rounded to 2
  - `SU_MCP::Bim::Route.turns(group)` → `Integer` (direction changes, i.e. joints)
  - `SU_MCP::Bim::Route.all(model)` → `Array<Sketchup::Group>`
  - `SU_MCP::Bim::MM_PER_INCH` = `25.4`

- [ ] **Step 1: Write the failing test**

Create `tests/test_bim.rb`:

```ruby
# Unit tests for the BIM layer. No SketchUp needed.
$LOAD_PATH.unshift(File.expand_path("stubs", __dir__))
require 'sketchup'
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd "/Users/Sang/Claude Code/repos/sketchup-mcp" && ruby tests/test_bim.rb`
Expected: FAIL — `cannot load such file -- ../su_mcp/su_mcp/bim/route`

- [ ] **Step 3: Extend the stub API**

In `tests/stubs/sketchup.rb`, add inside `module Geom` (create the module if absent, before `module Sketchup`):

```ruby
module Geom
  class Point3d
    attr_accessor :x, :y, :z
    def initialize(x = 0, y = 0, z = 0); @x = x.to_f; @y = y.to_f; @z = z.to_f; end
    def to_a; [@x, @y, @z]; end
    def distance(other)
      Math.sqrt((@x - other.x)**2 + (@y - other.y)**2 + (@z - other.z)**2)
    end
  end
end
```

Then inside `module Sketchup`, add an Edge and teach `Entities` to make them:

```ruby
  class Edge
    attr_reader :start, :end
    def initialize(a, b); @start = a; @end = b; end
    def length; @start.distance(@end); end
    def typename; "Edge"; end
  end
```

In `Sketchup::Entities`, add:

```ruby
    def add_edges(*points)
      pts = points.flatten
      edges = []
      pts.each_cons(2) { |a, b| edges << Edge.new(a, b) }
      edges.each { |e| @items << e }
      edges
    end
    def grep(klass); @items.grep(klass); end
```

In `Sketchup::Group`, add a definition that can hold attributes (Task 2 needs it too):

```ruby
    def definition; @definition ||= Definition.new(self); end
```

and a Definition class next to Group:

```ruby
  class Definition
    attr_reader :attribute_dictionaries
    def initialize(instance); @instance = instance; @dicts = {}; @classification = {}; end
    def set_attribute(dict, key, value); (@dicts[dict] ||= {})[key] = value; true; end
    def get_attribute(dict, key, fallback = nil); (@dicts[dict] || {}).fetch(key, fallback); end
    def attribute_dictionary(name, _create = false); @dicts[name]; end
    def set_classification_value(path, value); @classification[path.join("/")] = value; true; end
    def get_classification_value(path); @classification[path.join("/")]; end
    def name; @instance.name; end
  end
```

- [ ] **Step 4: Write minimal implementation**

Create `su_mcp/su_mcp/bim/route.rb`:

```ruby
module SU_MCP
  module Bim
    MM_PER_INCH = 25.4
    ROUTE_NAME  = "MEP Route".freeze

    # A centreline route is the ONLY source of a pipe's length. The extruded
    # solid is a picture: a bend, a joined run or a pipe cut by a wall all make
    # a solid report a wrong length, and the schedule cannot show that.
    module Route
      def self.create(model, points_mm)
        raise "A route needs at least two points" if points_mm.nil? || points_mm.length < 2

        pts = points_mm.map { |p| Geom::Point3d.new(p[0] / MM_PER_INCH, p[1] / MM_PER_INCH, p[2] / MM_PER_INCH) }
        group = model.entities.add_group
        group.entities.add_edges(pts)
        group.name = ROUTE_NAME
        group
      end

      def self.segments(group)
        group.entities.grep(Sketchup::Edge).map { |e| [e.start, e.end] }
      end

      def self.length_inches(group)
        segments(group).sum { |a, b| a.distance(b) }
      end

      def self.metres(group)
        (length_inches(group) * 0.0254).round(2)
      end

      # A joint is a direction change between consecutive segments. Colinear
      # segments are one straight run and cost no fitting.
      def self.turns(group)
        dirs = segments(group).map { |a, b| unit(a, b) }
        dirs.each_cons(2).count { |u, v| !colinear?(u, v) }
      end

      def self.all(model)
        model.entities.grep(Sketchup::Group).select { |g| g.name == ROUTE_NAME }
      end

      def self.unit(a, b)
        d = [b.x - a.x, b.y - a.y, b.z - a.z]
        m = Math.sqrt(d.sum { |c| c * c })
        m.zero? ? [0.0, 0.0, 0.0] : d.map { |c| c / m }
      end

      def self.colinear?(u, v)
        u.zip(v).sum { |a, b| a * b } > 0.9999
      end
    end
  end
end
```

- [ ] **Step 5: Wire it into the extension and run the tests**

In `su_mcp/su_mcp/main.rb`, directly under the existing `require 'tmpdir'` line, add:

```ruby
require_relative 'bim/route'
```

Run: `ruby tests/test_bim.rb`
Expected: PASS — `ALL BIM CHECKS PASSED`

Run: `ruby tests/test_extension.rb`
Expected: PASS — the existing suite must not regress.

- [ ] **Step 6: Commit**

```bash
git add su_mcp/su_mcp/bim/route.rb tests/test_bim.rb tests/stubs/sketchup.rb su_mcp/su_mcp/main.rb
git commit -m "bim: the centreline route, and why it is the only thing measured"
```

---

### Task 2: Label — IFC vocabulary, plus a side dictionary for what it lacks

**Files:**
- Create: `su_mcp/su_mcp/bim/label.rb`
- Modify: `tests/test_bim.rb` (append section 5)
- Modify: `su_mcp/su_mcp/main.rb` (require)

**Interfaces:**
- Consumes: `SU_MCP::Bim::Route.all`
- Produces:
  - `SU_MCP::Bim::Label.write(entity, system:, diameter_mm:, material:, ifc_class: "IfcPipeSegment")` → the label hash
  - `SU_MCP::Bim::Label.read(entity)` → `{ifc_class:, system:, diameter_mm:, material:}` or `nil`
  - `SU_MCP::Bim::Label.labelled?(entity)` → `true`/`false`
  - `SU_MCP::Bim::Label::DICT` = `"SU_MCP_MEP"`, `SU_MCP::Bim::Label::SCHEMA` = `"IFC 4"`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_bim.rb`, before the final summary lines:

```ruby
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby tests/test_bim.rb`
Expected: FAIL — `cannot load such file -- ../su_mcp/su_mcp/bim/label`

- [ ] **Step 3: Write minimal implementation**

Create `su_mcp/su_mcp/bim/label.rb`:

```ruby
module SU_MCP
  module Bim
    # Measured 2026-09-08 on SketchUp Pro 24.0.483: IFC 2x3 and IFC 4 schemas
    # are already loaded, and set/get_classification_value live on the
    # ComponentDefinition, not the instance. So the IFC class goes to the
    # classifier (which an IFC exporter would read) and the fields IFC has no
    # slot for go to one side dictionary.
    module Label
      DICT   = "SU_MCP_MEP".freeze
      SCHEMA = "IFC 4".freeze
      DEFAULT_CLASS = "IfcPipeSegment".freeze

      def self.write(entity, system:, diameter_mm:, material:, ifc_class: DEFAULT_CLASS)
        d = definition_of(entity)
        d.set_attribute(DICT, "ifc_class", ifc_class)
        d.set_attribute(DICT, "system", system.to_s)
        d.set_attribute(DICT, "diameter_mm", diameter_mm.to_i)
        d.set_attribute(DICT, "material", material.to_s)
        begin
          d.set_classification_value([SCHEMA, ifc_class], ifc_class)
        rescue StandardError
          # A file without the schema loaded still gets a usable label.
          nil
        end
        read(entity)
      end

      def self.read(entity)
        d = definition_of(entity)
        system = d.get_attribute(DICT, "system")
        return nil if system.nil? || system.to_s.empty?

        {
          ifc_class:   d.get_attribute(DICT, "ifc_class", DEFAULT_CLASS),
          system:      system,
          diameter_mm: d.get_attribute(DICT, "diameter_mm", 0).to_i,
          material:    d.get_attribute(DICT, "material", "")
        }
      end

      def self.labelled?(entity)
        !read(entity).nil?
      end

      def self.definition_of(entity)
        entity.respond_to?(:definition) ? entity.definition : entity
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

In `su_mcp/su_mcp/main.rb`, add under the Task 1 require:

```ruby
require_relative 'bim/label'
```

Run: `ruby tests/test_bim.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add su_mcp/su_mcp/bim/label.rb tests/test_bim.rb su_mcp/su_mcp/main.rb
git commit -m "bim: labels in IFC vocabulary, on the definition where the API puts them"
```

---

### Task 3: Storey — declared once, inferred from Z

**Files:**
- Create: `su_mcp/su_mcp/bim/storey.rb`
- Modify: `tests/test_bim.rb` (append section 8)
- Modify: `tests/stubs/sketchup.rb` (`Model#set_attribute` / `#get_attribute`)
- Modify: `su_mcp/su_mcp/main.rb` (require)

**Interfaces:**
- Consumes: `SU_MCP::Bim::MM_PER_INCH`
- Produces:
  - `SU_MCP::Bim::Storey.declare(model, storeys)` where `storeys` is `Array<{"name" => String, "elevation_mm" => Numeric}>` → the stored array
  - `SU_MCP::Bim::Storey.all(model)` → `Array<Hash>` sorted by elevation ascending
  - `SU_MCP::Bim::Storey.of(model, z_inches)` → `String` — the highest storey at or below z, or `"unassigned"`
  - `SU_MCP::Bim::Storey.of_route(model, group)` → `String` — uses the route's lowest point
  - `SU_MCP::Bim::Storey::UNASSIGNED` = `"unassigned"`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_bim.rb`:

```ruby
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby tests/test_bim.rb`
Expected: FAIL — `cannot load such file -- ../su_mcp/su_mcp/bim/storey`

- [ ] **Step 3: Teach the stub model to hold attributes**

In `tests/stubs/sketchup.rb`, inside `class Model`, add:

```ruby
    def set_attribute(dict, key, value); ((@dicts ||= {})[dict] ||= {})[key] = value; true; end
    def get_attribute(dict, key, fallback = nil); ((@dicts ||= {})[dict] || {}).fetch(key, fallback); end
```

- [ ] **Step 4: Write minimal implementation**

Create `su_mcp/su_mcp/bim/storey.rb`:

```ruby
require 'json'

module SU_MCP
  module Bim
    # Labelling every pipe with its storey by hand is the step nobody keeps up.
    # Declare the elevations once and read the storey off the geometry instead.
    module Storey
      DICT       = "SU_MCP_MEP".freeze
      KEY        = "storeys".freeze
      UNASSIGNED = "unassigned".freeze

      def self.declare(model, storeys)
        clean = storeys.map do |s|
          name = (s["name"] || s[:name]).to_s
          raise "Every storey needs a name" if name.empty?
          { "name" => name, "elevation_mm" => (s["elevation_mm"] || s[:elevation_mm]).to_f }
        end
        model.set_attribute(DICT, KEY, JSON.generate(clean))
        all(model)
      end

      def self.all(model)
        raw = model.get_attribute(DICT, KEY, nil)
        return [] if raw.nil? || raw.to_s.empty?

        JSON.parse(raw).sort_by { |s| s["elevation_mm"] }
      end

      def self.of(model, z_inches)
        z_mm = z_inches * MM_PER_INCH
        below = all(model).select { |s| s["elevation_mm"] <= z_mm + 1e-6 }
        below.empty? ? UNASSIGNED : below.last["name"]
      end

      def self.of_route(model, group)
        zs = Route.segments(group).flatten.map(&:z)
        return UNASSIGNED if zs.empty?

        of(model, zs.min)
      end
    end
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Add `require_relative 'bim/storey'` to `main.rb` under the Task 2 require.

Run: `ruby tests/test_bim.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add su_mcp/su_mcp/bim/storey.rb tests/test_bim.rb tests/stubs/sketchup.rb su_mcp/su_mcp/main.rb
git commit -m "bim: storeys declared once, read off the geometry after that"
```

---

### Task 4: Schedule — grouped totals, and the unlabelled row

**Files:**
- Create: `su_mcp/su_mcp/bim/schedule.rb`
- Modify: `tests/test_bim.rb` (append section 10)
- Modify: `su_mcp/su_mcp/main.rb` (require)

**Interfaces:**
- Consumes: `Route.all`, `Route.metres`, `Route.turns`, `Label.read`, `Storey.of_route`
- Produces:
  - `SU_MCP::Bim::Schedule.build(model)` → `{ rows: Array<Hash>, unlabelled: Hash, total_metres: Float }` where a row is `{ "system" => String, "diameter_mm" => Integer, "storey" => String, "metres" => Float, "joints" => Integer, "routes" => Integer }` and `unlabelled` is `{ "routes" => Integer, "metres" => Float }`
  - Rows sorted by system, then diameter, then storey.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_bim.rb`:

```ruby
require_relative '../su_mcp/su_mcp/bim/schedule'
SCH = SU_MCP::Bim::Schedule

puts "\n[10] the schedule groups by system, diameter and storey"
model2 = Sketchup::Model.new
S.declare(model2, [{ "name" => "L1", "elevation_mm" => 0 }])
a = R.create(model2, [[0, 0, 0], [4000, 0, 0]])            # 4.00 m
b = R.create(model2, [[0, 500, 0], [2000, 500, 0]])        # 2.00 m, same system+size
c = R.create(model2, [[0, 0, 0], [1000, 0, 0], [1000, 0, 1000]]) # 2.00 m, 1 turn, other size
L.write(a, system: "cold_water", diameter_mm: 50, material: "PPR")
L.write(b, system: "cold_water", diameter_mm: 50, material: "PPR")
L.write(c, system: "cold_water", diameter_mm: 25, material: "PPR")
orphan = R.create(model2, [[0, 0, 0], [3000, 0, 0]])       # 3.00 m, no label

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
R.create(model2, []) rescue nil
before = SCH.build(model2)[:total_metres]
a.entities.add_edges([Geom::Point3d.new(4000 / 25.4, 0, 0), Geom::Point3d.new(6000 / 25.4, 0, 0)])
after = SCH.build(model2)[:total_metres]
check(failures, "length changes when the model changes", after == (before + 2.0).round(2), "#{before} -> #{after}")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby tests/test_bim.rb`
Expected: FAIL — `cannot load such file -- ../su_mcp/su_mcp/bim/schedule`

- [ ] **Step 3: Write minimal implementation**

Create `su_mcp/su_mcp/bim/schedule.rb`:

```ruby
module SU_MCP
  module Bim
    # Read fresh every time: the owner can drag a route between two runs, and a
    # cached length would price the old model. Unlabelled routes get their own
    # row — a wrong number is visible, an omitted pipe is not.
    module Schedule
      def self.build(model)
        rows = {}
        unlabelled = { "routes" => 0, "metres" => 0.0 }

        Route.all(model).each do |group|
          metres = Route.metres(group)
          label  = Label.read(group)

          if label.nil?
            unlabelled["routes"] += 1
            unlabelled["metres"] = (unlabelled["metres"] + metres).round(2)
            next
          end

          key = [label[:system], label[:diameter_mm], Storey.of_route(model, group)]
          row = rows[key] ||= {
            "system" => key[0], "diameter_mm" => key[1], "storey" => key[2],
            "material" => label[:material], "metres" => 0.0, "joints" => 0, "routes" => 0
          }
          row["metres"] = (row["metres"] + metres).round(2)
          row["joints"] += Route.turns(group)
          row["routes"] += 1
        end

        sorted = rows.values.sort_by { |r| [r["system"], r["diameter_mm"], r["storey"]] }
        total  = (sorted.sum { |r| r["metres"] } + unlabelled["metres"]).round(2)

        { rows: sorted, unlabelled: unlabelled, total_metres: total }
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Add `require_relative 'bim/schedule'` to `main.rb`.

Run: `ruby tests/test_bim.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add su_mcp/su_mcp/bim/schedule.rb tests/test_bim.rb su_mcp/su_mcp/main.rb
git commit -m "bim: the schedule, with the unlabelled routes on their own row"
```

---

### Task 5: Export — a CSV a contractor can open

**Files:**
- Create: `su_mcp/su_mcp/bim/export.rb`
- Modify: `tests/test_bim.rb` (append section 12)
- Modify: `su_mcp/su_mcp/main.rb` (require)

**Interfaces:**
- Consumes: `Schedule.build`
- Produces:
  - `SU_MCP::Bim::Export.csv(schedule, path)` → the path written
  - `SU_MCP::Bim::Export.default_path(model)` → `String` — `<export dir>/<model title>-mep-schedule.csv`, honouring `SKETCHUP_MCP_EXPORT_DIR`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_bim.rb`:

```ruby
require_relative '../su_mcp/su_mcp/bim/export'
EX = SU_MCP::Bim::Export

puts "\n[12] the CSV carries the unlabelled row too"
path = File.join(Dir.tmpdir, "mep_test_schedule.csv")
File.delete(path) if File.exist?(path)
EX.csv(SCH.build(model2), path)
lines = File.readlines(path).map(&:chomp)
check(failures, "file written", File.exist?(path))
check(failures, "header first", lines.first == "system,diameter_mm,storey,material,metres,joints,routes", lines.first)
check(failures, "unlabelled present in the file", lines.any? { |l| l.start_with?("UNLABELLED,") }, lines.inspect)
check(failures, "total row last", lines.last.start_with?("TOTAL,"), lines.last)
check(failures, "a comma in a value cannot break a column",
      EX.send(:cell, 'PPR, white').start_with?('"'), EX.send(:cell, 'PPR, white'))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby tests/test_bim.rb`
Expected: FAIL — `cannot load such file -- ../su_mcp/su_mcp/bim/export`

- [ ] **Step 3: Write minimal implementation**

Create `su_mcp/su_mcp/bim/export.rb`:

```ruby
require 'tmpdir'

module SU_MCP
  module Bim
    module Export
      HEADER = %w[system diameter_mm storey material metres joints routes].freeze

      def self.csv(schedule, path)
        File.open(path, "w") do |f|
          f.puts HEADER.join(",")
          schedule[:rows].each do |r|
            f.puts HEADER.map { |h| cell(r[h]) }.join(",")
          end
          u = schedule[:unlabelled]
          if u["routes"].to_i > 0
            f.puts ["UNLABELLED", "", "", "", cell(u["metres"]), "", cell(u["routes"])].join(",")
          end
          f.puts ["TOTAL", "", "", "", cell(schedule[:total_metres]), "", ""].join(",")
        end
        path
      end

      def self.default_path(model)
        dir   = ENV['SKETCHUP_MCP_EXPORT_DIR'] || Dir.tmpdir
        title = model.title.to_s.empty? ? "untitled" : model.title
        File.join(dir, "#{title}-mep-schedule.csv")
      end

      # A material called "PPR, white" would otherwise shift every later column.
      def self.cell(value)
        s = value.to_s
        s =~ /[",\n]/ ? '"' + s.gsub('"', '""') + '"' : s
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Add `require_relative 'bim/export'` to `main.rb`.

Run: `ruby tests/test_bim.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add su_mcp/su_mcp/bim/export.rb tests/test_bim.rb su_mcp/su_mcp/main.rb
git commit -m "bim: CSV export, with quoting so one comma cannot shift a column"
```

---

### Task 6: The six MCP tools, end to end

**Files:**
- Modify: `su_mcp/su_mcp/main.rb` (`MUTATING_TOOLS`, `dispatch_tool`, six new private methods)
- Modify: `src/sketchup_mcp/server.py` (six `@mcp.tool()` wrappers)
- Modify: `tests/test_end_to_end.py` (append a MEP section)

**Interfaces:**
- Consumes: every unit from Tasks 1–5.
- Produces these tool names on both sides, arguments identical:
  - `mep_create_route(points_mm, system, diameter_mm, material, ifc_class)` → `{success, id, metres, storey}`
  - `mep_label(id, system, diameter_mm, material, ifc_class)` → `{success, id, label}`
  - `mep_declare_storeys(storeys)` → `{success, storeys}`
  - `mep_unlabelled()` → `{success, routes:[{id, metres}]}`
  - `mep_schedule()` → `{success, rows, unlabelled, total_metres}`
  - `mep_export_schedule(path)` → `{success, path}`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_end_to_end.py` before its summary:

```python
First update the tool-count assertion near the top of the file, which is exact
and will otherwise fail: `len(names) == 15` becomes `len(names) == 21` (this task
adds six; Task 8 adds the twenty-second).

Then append inside `main`, at the same indentation as the other sections, before
the summary:

```python
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
```

This suite runs against `tests/fake_sketchup_host.rb`, which loads the real
`main.rb` — so it exercises the Ruby tools without SketchUp. It does not
exercise real geometry; that is what the live check in the closing notes is for.

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/python tests/test_end_to_end.py`
Expected: FAIL — `Unknown tool: mep_declare_storeys`

- [ ] **Step 3: Add the Ruby tools**

In `su_mcp/su_mcp/main.rb`, extend `MUTATING_TOOLS` with the three that write:

```ruby
    mep_create_route mep_label mep_declare_storeys
```

Add to `dispatch_tool`, above the `else`:

```ruby
      when "mep_create_route"     then mep_create_route(args)
      when "mep_label"            then mep_label(args)
      when "mep_declare_storeys"  then mep_declare_storeys(args)
      when "mep_unlabelled"       then mep_unlabelled
      when "mep_schedule"         then mep_schedule
      when "mep_export_schedule"  then mep_export_schedule(args)
```

Add these methods next to the other tool implementations (inside `class Server`, after `eval_ruby`):

```ruby
    def mep_create_route(params)
      model  = Sketchup.active_model
      points = params["points_mm"] || params["points"]
      group  = Bim::Route.create(model, points)
      if params["system"]
        Bim::Label.write(
          group,
          system: params["system"],
          diameter_mm: params["diameter_mm"],
          material: params["material"] || "",
          ifc_class: params["ifc_class"] || Bim::Label::DEFAULT_CLASS
        )
      end
      {
        success: true, id: group.entityID,
        metres: Bim::Route.metres(group),
        storey: Bim::Storey.of_route(model, group)
      }
    end

    def mep_label(params)
      model  = Sketchup.active_model
      entity = model.find_entity_by_id(params["id"].to_i)
      raise "No entity #{params["id"]}" unless entity

      label = Bim::Label.write(
        entity,
        system: params["system"],
        diameter_mm: params["diameter_mm"],
        material: params["material"] || "",
        ifc_class: params["ifc_class"] || Bim::Label::DEFAULT_CLASS
      )
      { success: true, id: entity.entityID, label: label }
    end

    def mep_declare_storeys(params)
      { success: true, storeys: Bim::Storey.declare(Sketchup.active_model, params["storeys"] || []) }
    end

    def mep_unlabelled
      model = Sketchup.active_model
      routes = Bim::Route.all(model).reject { |g| Bim::Label.labelled?(g) }
      { success: true, routes: routes.map { |g| { id: g.entityID, metres: Bim::Route.metres(g) } } }
    end

    def mep_schedule
      Bim::Schedule.build(Sketchup.active_model).merge(success: true)
    end

    def mep_export_schedule(params)
      model = Sketchup.active_model
      path  = params["path"].to_s.empty? ? Bim::Export.default_path(model) : params["path"]
      { success: true, path: Bim::Export.csv(Bim::Schedule.build(model), path) }
    end
```

- [ ] **Step 4: Add the Python tools**

In `src/sketchup_mcp/server.py`, after the existing tools:

```python
@mcp.tool()
def mep_declare_storeys(storeys: List[Dict[str, Any]]) -> str:
    """Declare the building's storeys once: [{"name": "L1", "elevation_mm": 0}, ...].

    Every route's storey is then inferred from its height, so pipes never need
    labelling with a storey by hand.
    """
    return call_tool("mep_declare_storeys", {"storeys": storeys})


@mcp.tool()
def mep_create_route(
    points_mm: List[List[float]],
    system: str = None,
    diameter_mm: int = None,
    material: str = "",
    ifc_class: str = "IfcPipeSegment",
) -> str:
    """Draw a pipe centreline through points (millimetres) and label it.

    The centreline is what every quantity is measured from — never the extruded
    solid. Omit system/diameter_mm to draw an unlabelled route; it will show up
    in the schedule's unlabelled row until you label it.
    """
    return call_tool("mep_create_route", {
        "points_mm": points_mm, "system": system,
        "diameter_mm": diameter_mm, "material": material, "ifc_class": ifc_class,
    })


@mcp.tool()
def mep_label(
    id: str,
    system: str,
    diameter_mm: int,
    material: str = "",
    ifc_class: str = "IfcPipeSegment",
) -> str:
    """Label an existing route: system, nominal diameter in mm, material, IFC class."""
    return call_tool("mep_label", {
        "id": id, "system": system, "diameter_mm": diameter_mm,
        "material": material, "ifc_class": ifc_class,
    })


@mcp.tool()
def mep_unlabelled() -> str:
    """List routes carrying no label, with their ids and lengths."""
    return call_tool("mep_unlabelled", {})


@mcp.tool()
def mep_schedule() -> str:
    """The quantity schedule: metres, joints and route count per system, diameter and storey.

    Unlabelled routes are reported separately rather than dropped.
    """
    return call_tool("mep_schedule", {})


@mcp.tool()
def mep_export_schedule(path: str = "") -> str:
    """Write the schedule as CSV and return the path. Defaults next to the model title."""
    return call_tool("mep_export_schedule", {"path": path})
```

- [ ] **Step 5: Run every suite**

Run: `ruby tests/test_bim.rb && ruby tests/test_extension.rb`
Expected: both PASS

Run: `.venv/bin/python tests/test_transport.py && .venv/bin/python tests/test_end_to_end.py`
Expected: both PASS

- [ ] **Step 6: Commit**

```bash
git add su_mcp/su_mcp/main.rb src/sketchup_mcp/server.py tests/test_end_to_end.py
git commit -m "mep: six tools, so an agent can route, label and price without Ruby"
```

---

### Task 7: The schedule in the panel

**Files:**
- Modify: `su_mcp/su_mcp/panel.html`
- Modify: `su_mcp/su_mcp/main.rb` (`SU_MCP.state`, two new panel callbacks)
- Modify: `tests/test_extension.rb` (append section 16)
- Modify: `.claude/design-manifest.md` (inventory row for the schedule table)

**Interfaces:**
- Consumes: `Bim::Schedule.build`, `Bim::Export.csv`
- Produces:
  - panel callbacks `schedule` and `export_schedule`
  - `render()` in the page keeps its existing contract and gains `s.schedule` (`{rows, unlabelled, total_metres}` or `null`)

- [ ] **Step 1: Write the failing test**

Append to `tests/test_extension.rb` before `sock.close`:

```ruby
puts "\n[16] the panel can show and export the schedule"
panel.invoke("schedule")
st = panel.last_state
check(failures, "schedule pushed to the panel", st.key?("schedule"), st.keys.inspect)
check(failures, "unlabelled block always present", st["schedule"]["unlabelled"].is_a?(Hash), st["schedule"].inspect)

out = File.join(Dir.tmpdir, "panel_schedule.csv")
File.delete(out) if File.exist?(out)
panel.invoke("export_schedule", out)
check(failures, "export writes the file the panel asked for", File.exist?(out))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby tests/test_extension.rb`
Expected: FAIL — `key?("schedule")` is false

- [ ] **Step 3: Add the callbacks**

In `main.rb`, extend `SU_MCP.state` with the schedule (kept `nil` until asked, so opening the panel stays cheap):

```ruby
  def self.state
    {
      running:   @server.running?,
      host:      @server.host,
      port:      @server.port,
      autostart: autostart?,
      error:     @server.last_error,
      schedule:  @schedule
    }
  end
```

and register two more callbacks inside `show_panel`, next to the existing ones:

```ruby
    @panel.add_action_callback("schedule") do
      @schedule = Bim::Schedule.build(Sketchup.active_model)
      push_state
    end
    @panel.add_action_callback("export_schedule") do |_ctx, path|
      target = path.to_s.empty? ? Bim::Export.default_path(Sketchup.active_model) : path
      Bim::Export.csv(Bim::Schedule.build(Sketchup.active_model), target)
      push_state
    end
```

- [ ] **Step 4: Add the table to the page**

In `su_mcp/su_mcp/panel.html`, add to the token block:

```css
    --warn: #B26A00;
```

Add markup after the `.opt` label:

```html
  <hr>

  <div class="actions">
    <button id="refresh">Schedule</button>
    <button id="export">Export CSV</button>
  </div>

  <div id="unlabelled" class="warn" hidden></div>
  <table id="rows"></table>
```

Add styles next to the existing rules:

```css
  .warn { margin-top: 8px; font-size: 12px; color: var(--warn); }
  table { width: 100%; border-collapse: collapse; margin-top: 8px; font-size: 12px; }
  th, td { text-align: left; padding: 3px 4px; border-bottom: 1px solid var(--line); }
  td.num { text-align: right; font-variant-numeric: tabular-nums; }
```

Extend `render()` — keep every existing line and append:

```javascript
    var s2 = s.schedule;
    var tbl = document.getElementById('rows');
    var warn = document.getElementById('unlabelled');
    if (!s2) { tbl.innerHTML = ''; warn.hidden = true; return; }

    var head = '<tr><th>System</th><th>ø</th><th>Storey</th><th class="num">m</th></tr>';
    tbl.innerHTML = head + s2.rows.map(function (r) {
      return '<tr><td>' + r.system + '</td><td>' + r.diameter_mm +
             '</td><td>' + r.storey + '</td><td class="num">' + r.metres.toFixed(2) + '</td></tr>';
    }).join('') +
      '<tr><td colspan="3"><b>Total</b></td><td class="num"><b>' +
      s2.total_metres.toFixed(2) + '</b></td></tr>';

    warn.hidden = !(s2.unlabelled && s2.unlabelled.routes > 0);
    if (!warn.hidden) {
      warn.textContent = s2.unlabelled.routes + ' unlabelled route(s), ' +
        s2.unlabelled.metres.toFixed(2) + ' m not priced';
    }
```

and the two handlers:

```javascript
  document.getElementById('refresh').onclick = function () { call('schedule'); };
  document.getElementById('export').onclick = function () { call('export_schedule', ''); };
```

Grow the dialog so the table has room — in `show_panel`, change `height: 210` to `height: 420`.

- [ ] **Step 5: Run the suites and look at the page**

Run: `ruby tests/test_extension.rb && ruby tests/test_bim.rb`
Expected: both PASS

Then verify the page renders in both states by copying it to a live preview and calling `render()` with a schedule that has an unlabelled row, and one with none. Confirm: numbers right-aligned, the unlabelled warning visible only when routes > 0, no horizontal scrollbar at 300px wide.

- [ ] **Step 6: Reinstall and commit**

```bash
PLUG="$HOME/Library/Application Support/SketchUp 2024/SketchUp/Plugins"
rm -rf "$PLUG/su_mcp" && cp -R su_mcp/su_mcp "$PLUG/su_mcp"
cp su_mcp/su_mcp.rb "$PLUG/su_mcp.rb" && cp su_mcp/extension.json "$PLUG/su_mcp/extension.json"
git add su_mcp/su_mcp/panel.html su_mcp/su_mcp/main.rb tests/test_extension.rb .claude/design-manifest.md
git commit -m "panel: the schedule, and the unlabelled metres in a colour you cannot miss"
```

Then bump `ext.version`, `extension.json` version and `package.rb` VERSION to `1.9.0` in one commit, and tell the owner to restart SketchUp.

---

### Task 8: The pipe solid — a picture, never a measurement

**Files:**
- Create: `su_mcp/su_mcp/bim/solid.rb`
- Modify: `tests/test_bim.rb` (append section 13)
- Modify: `su_mcp/su_mcp/main.rb` (require, `MUTATING_TOOLS`, dispatch, one method)
- Modify: `src/sketchup_mcp/server.py` (one tool)

**Interfaces:**
- Consumes: `Route.segments`, `Label.read`
- Produces:
  - `SU_MCP::Bim::Solid.build(model, route_group)` → `Sketchup::Group` named `"MEP Pipe"`, or raises if the route has no label (a diameter is required to extrude)
  - `SU_MCP::Bim::Solid.rebuild_all(model)` → `Integer` count built
  - tool `mep_build_solids()` → `{success, built}`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_bim.rb`:

```ruby
require_relative '../su_mcp/su_mcp/bim/solid'
SO = SU_MCP::Bim::Solid

puts "\n[13] the solid is built from the route, and never measured"
solid = SO.build(model2, a)
check(failures, "named so the schedule can ignore it", solid.name == "MEP Pipe", solid.name)
check(failures, "solids are not routes", SU_MCP::Bim::Route.all(model2).none? { |g| g.name == "MEP Pipe" })
before = SCH.build(model2)[:total_metres]
SO.build(model2, b)
check(failures, "building a solid does not change any quantity", SCH.build(model2)[:total_metres] == before, SCH.build(model2)[:total_metres])

puts "\n[14] extruding needs a diameter"
begin
  SO.build(model2, orphan)
  check(failures, "unlabelled route refused", false, "no raise")
rescue StandardError => e
  check(failures, "unlabelled route refused", e.message.include?("diameter"), e.message)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby tests/test_bim.rb`
Expected: FAIL — `cannot load such file -- ../su_mcp/su_mcp/bim/solid`

- [ ] **Step 3: Write minimal implementation**

Create `su_mcp/su_mcp/bim/solid.rb`:

```ruby
module SU_MCP
  module Bim
    # Looks only. Nothing in the schedule reads this group, which is why it can
    # be deleted and rebuilt at will without a number moving.
    module Solid
      NAME = "MEP Pipe".freeze

      def self.build(model, route_group)
        label = Label.read(route_group)
        raise "Cannot extrude without a diameter: label the route first" if label.nil? || label[:diameter_mm].to_i <= 0

        radius = (label[:diameter_mm].to_f / 2) / MM_PER_INCH
        group  = model.entities.add_group
        Route.segments(route_group).each do |a, b|
          circle = group.entities.add_circle(a, direction(a, b), radius, 12)
          face   = group.entities.add_face(circle)
          face.pushpull(-a.distance(b)) if face
        end
        group.name = NAME
        group
      end

      def self.rebuild_all(model)
        model.entities.grep(Sketchup::Group).select { |g| g.name == NAME }.each(&:erase!)
        Route.all(model).count { |r| Label.labelled?(r) && build(model, r) }
      end

      def self.direction(a, b)
        Geom::Vector3d.new(b.x - a.x, b.y - a.y, b.z - a.z)
      end
    end
  end
end
```

Add to the stub, inside `Sketchup::Entities`:

```ruby
    def add_circle(_center, _normal, radius, _segments = 12)
      @items << (c = Edge.new(Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(radius, 0, 0)))
      [c]
    end
```

and inside `module Geom`:

```ruby
  class Vector3d
    attr_reader :x, :y, :z
    def initialize(x, y, z); @x = x; @y = y; @z = z; end
  end
```

and in `Sketchup::Group`, so `rebuild_all` can clear old solids:

```ruby
    def erase!; true; end
```

- [ ] **Step 4: Wire and run**

Add `require_relative 'bim/solid'` to `main.rb`, add `mep_build_solids` to `MUTATING_TOOLS`, add the dispatch line `when "mep_build_solids" then mep_build_solids`, and the method:

```ruby
    def mep_build_solids
      { success: true, built: Bim::Solid.rebuild_all(Sketchup.active_model) }
    end
```

In `server.py`:

```python
@mcp.tool()
def mep_build_solids() -> str:
    """Extrude every labelled route into a visible pipe, replacing earlier ones.

    Cosmetic only: quantities always come from the centrelines, so deleting or
    rebuilding these changes no number.
    """
    return call_tool("mep_build_solids", {})
```

Update the tool-count assertion in `tests/test_end_to_end.py` from 21 to 22.

Run: `ruby tests/test_bim.rb && ruby tests/test_extension.rb && .venv/bin/python tests/test_end_to_end.py`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add su_mcp/su_mcp/bim/solid.rb tests/stubs/sketchup.rb tests/test_bim.rb su_mcp/su_mcp/main.rb src/sketchup_mcp/server.py
git commit -m "mep: pipes you can see, kept out of everything that counts"
```

---

## Notes for whoever executes this

- **Verify in the real SketchUp after Task 6 and Task 8**, not only in the stubs. The stub's `add_circle`/`pushpull` are stand-ins; a real extrusion can fail on a zero-length segment or a duplicated point. Drive it through the live bridge on port 9876 and read back `mep_schedule` — the numbers must not move when solids appear.
- **The IFC file is still not exportable on this machine** (`model.export` refuses `.ifc`, no exporter extension installed). Do not add a tool that pretends otherwise. When the owner installs one, the classifier values written in Task 2 are what it will read.
- `su_mcp/su_mcp/main.rb` is the extension's only entry point; the installed copy lives in `~/Library/Application Support/SketchUp 2024/SketchUp/Plugins/su_mcp/`. Every task that changes Ruby needs a reinstall and a SketchUp restart before it can be seen in the app.
