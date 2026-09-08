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
        d.set_attribute(DICT, "ifc_bound", bind_classification(d, ifc_class))
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
          material:    d.get_attribute(DICT, "material", ""),
          ifc_bound:   !!d.get_attribute(DICT, "ifc_bound", false)
        }
      end

      # Measured on SketchUp Pro 24.0.483, 2026-09-08: `m.classifications` lists
      # IFC 2x3 and IFC 4 and the four classification methods all respond, yet
      # `add_classification` returns FALSE for every class tried — IfcWall
      # included, on a real ComponentDefinition as well as a group. So the
      # schemas are listed but nothing attaches through Ruby on this install.
      #
      # The label is therefore carried by DICT, which does work, and whether the
      # classifier accepted it is recorded rather than swallowed. A silent
      # rescue here is what made an earlier run look like IFC data was being
      # written when none was. Nothing reads `ifc_bound` yet; it exists so the
      # day an IFC exporter is installed, the gap is visible instead of assumed.
      def self.bind_classification(definition, ifc_class)
        return false unless definition.respond_to?(:add_classification)

        !!definition.add_classification(SCHEMA, ifc_class)
      rescue StandardError
        false
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
