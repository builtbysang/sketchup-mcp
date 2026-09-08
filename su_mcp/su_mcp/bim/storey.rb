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
        z_mm  = z_inches * MM_PER_INCH
        below = all(model).select { |s| s["elevation_mm"] <= z_mm + 1e-6 }
        below.empty? ? UNASSIGNED : below.last["name"]
      end

      # A riser spans two storeys; it belongs to the one it starts from. Splitting
      # it would count the same pipe twice, which is worse than putting it on the
      # lower floor.
      def self.of_route(model, group)
        zs = Route.segments(group).flatten.map(&:z)
        return UNASSIGNED if zs.empty?

        of(model, zs.min)
      end
    end
  end
end
