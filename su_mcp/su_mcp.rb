require 'sketchup'
require 'extensions'

module SU_MCP
  unless file_loaded?(__FILE__)
    ext = SketchupExtension.new('Phanton Sketchup MCP', 'su_mcp/main')
    ext.description = 'Model Context Protocol server for Sketchup'
    ext.version     = '1.10.0'
    ext.copyright   = '2024'
    ext.creator     = 'MCP Team'
    
    Sketchup.register_extension(ext, true)
    
    file_loaded(__FILE__)
  end
end 