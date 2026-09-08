# Simple BIM for architecture: MEP quantities out of SketchUp

Date: 2026-09-08
Status: approved (owner approved the design in conversation; the owner does not
read spec files — this document is for future sessions, not a review gate)

## Goal

Get a **quantity schedule** out of a SketchUp model: how many metres of pipe per
diameter per system per storey, how many fittings. Water/MEP first. The schedule
is what a contractor prices from, and today it is produced by hand.

## Why this shape

SketchUp is a surface modeller: a solid does not know it is a wall. "BIM-like"
here means picking a subset, and the subset is chosen by what the owner needs
priced. Measured on this machine 2026-09-08:

- SketchUp **Pro** 24.0.483 lists **IFC 2x3 and IFC 4** in `model.classifications`
  and all four classification methods respond on a ComponentDefinition.
  **Corrected 2026-09-08 after driving the live model:** responding is not
  working. `add_classification` returns **false for every class tried** —
  `IfcWall`, `IfcBuildingElementProxy`, `IfcFlowSegment`, `IfcPipeSegment` —
  on a real ComponentDefinition as well as on a group, and nothing reads back.
  The earlier claim in this spec came from `respond_to?`, which proves nothing.
  So the label lives in one attribute dictionary (which does work), each write
  records whether the classifier accepted it (`ifc_bound`), and attaching real
  IFC classes is an open research item — not a thing to assume is happening.
- **No IFC exporter** is installed: `model.export("x.ifc")` returns *Unsupported
  file extension*, and none of the 7 installed extensions provides one. So an
  IFC **file** cannot be produced here yet. Writing IFC-shaped data is free;
  emitting IFC is not, and needs an extension the owner installs.

Hence: label in IFC *vocabulary* (the class name is stored even though the
classifier will not take it), ship a CSV schedule, and treat both halves of the
IFC story — attaching classes, and emitting a file — as open. The contractor
wants the schedule; only a partner opening the *model* in Revit wants IFC.

**Verified on the live model 2026-09-08**, with the routes erased afterwards so
the file was left as found: a two-segment route measured 6.00 m, one turn,
storey L1; an unlabelled route surfaced as 3.00 m in its own row; the CSV came
out with the UNLABELLED and TOTAL rows. Two bugs the stub had hidden were found
this way — `Edge#start` returns a **Vertex**, not a point, and the classifier
write was a silent no-op.

## The root decision: the route is the truth, the pipe is the picture

The owner has never modelled pipes, so the convention is ours to set:

1. A **centreline route** is drawn (points → segments).
2. The route carries the labels: IFC class, system, nominal diameter, material.
3. The route is optionally extruded into a **visible pipe solid**.
4. **Every number comes from the route, never from the solid.**

Measuring a solid is the classic trap: a bend, two pipes joined, or a pipe cut
by a wall all yield a wrong length, and the schedule gives no sign of it. A
route's length is a sum of segments — there is nowhere for it to go wrong. The
solid can be deleted and rebuilt at will without touching a number.

## Units of the system

| Unit | Does | Depends on |
|---|---|---|
| Route | Holds the centreline geometry; creates one from a point list; reads its segment lengths | — |
| Label | Writes/reads IFC class (`IfcPipeSegment`, `IfcPipeFitting`, `IfcFlowTerminal`) plus system, nominal diameter (mm), material. IFC vocabulary where it exists, a side dictionary only for what it lacks | Route |
| Storey | Owner declares storey names + elevations once; a route's storey is inferred from its Z | — |
| Pipe solid | Extrudes a route into a cylinder for looks. Rebuildable, never read for numbers | Route, Label (diameter) |
| Schedule | Groups by system × diameter × storey: total metres, joint count (from direction changes), fitting count | Route, Label, Storey |
| Export | Writes the schedule as CSV (opens in Excel) | Schedule |
| MCP tools | create_route, label_entity, declare_storeys, list_unlabelled, get_schedule, export_schedule | all of the above |
| Panel | Shows the schedule inside SketchUp with an export button | Schedule, Export |

Data flow: points → route (+labels) → [solid, for looks] → grouped schedule → CSV.

## Failure modes designed against

- **Missing is worse than wrong.** An unlabelled route MUST appear as its own
  "unlabelled" row in the schedule, never be silently skipped. A wrong number is
  visible; an omitted pipe is not.
- **Units.** The model is in millimetres; the schedule reports **metres to 2
  decimals**. One conversion, one place.
- **Hand edits.** Lengths are read fresh on every schedule run — never cached on
  the entity — because the owner can drag a route in SketchUp at any time.
- **Diameter list.** Free millimetre entry with a suggested list of the sizes
  common in Vietnam (20, 25, 32, 40, 50, 63, 75, 90, 110). Not a closed
  enumeration: an unusual size must not require a code change.

## Verification

The repo already runs three suites with no SketchUp needed
(`tests/stubs/sketchup.rb`). Extend that: build a synthetic 3-segment route,
label it, run the schedule, compare the total against a hand-computed number.
Add a case for an unlabelled route appearing in its own row, and one for a route
crossing a storey boundary.

## Out of scope

Structural steel and rebar, electrical and panels, IFC file emission, Gemini
rendering (parked by the owner on 2026-09-08), clash detection. All of them
reuse this label set and this schedule grouping, so each is cheaper after MEP
lands than before it.
