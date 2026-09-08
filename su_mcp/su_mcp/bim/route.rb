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

        pts = points_mm.map do |p|
          Geom::Point3d.new(p[0] / MM_PER_INCH, p[1] / MM_PER_INCH, p[2] / MM_PER_INCH)
        end
        group = model.entities.add_group
        group.entities.add_edges(pts)
        group.name = ROUTE_NAME
        group
      end

      # Edge#start / #end are vertices, not points: the point is one hop further.
      def self.segments(group)
        group.entities.grep(Sketchup::Edge).map { |e| [e.start.position, e.end.position] }
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
