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
