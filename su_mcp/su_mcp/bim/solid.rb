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
          length = a.distance(b)
          next if length <= 0

          circle = group.entities.add_circle(a, direction(a, b), radius, 12)
          face   = group.entities.add_face(circle)
          next unless face

          # The face normal follows the circle normal, so a negative pull would
          # extrude away from b and leave the pipe on the wrong side.
          face.pushpull(face.normal.dot(direction(a, b)) < 0 ? -length : length)
        end
        group.name = NAME
        group
      end

      def self.rebuild_all(model)
        model.entities.grep(Sketchup::Group).select { |g| g.name == NAME }.each(&:erase!)
        Route.all(model).count { |r| Label.labelled?(r) && build(model, r) }
      end

      def self.all(model)
        model.entities.grep(Sketchup::Group).select { |g| g.name == NAME }
      end

      def self.direction(a, b)
        Geom::Vector3d.new(b.x - a.x, b.y - a.y, b.z - a.z)
      end
    end
  end
end
