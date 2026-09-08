require 'tmpdir'

module SU_MCP
  module Bim
    module Export
      HEADER = %w[system diameter_mm storey material metres joints routes].freeze

      def self.csv(schedule, path)
        File.open(path, "w") do |f|
          f.puts HEADER.join(",")
          schedule[:rows].each { |r| f.puts HEADER.map { |h| cell(r[h]) }.join(",") }

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
