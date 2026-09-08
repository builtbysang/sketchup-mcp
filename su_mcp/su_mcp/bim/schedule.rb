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
