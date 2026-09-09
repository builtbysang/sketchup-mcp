require 'sketchup'
require 'json'
require 'socket'
require 'fileutils'
require 'tmpdir'

require_relative 'bim/route'
require_relative 'bim/label'
require_relative 'bim/storey'
require_relative 'bim/schedule'
require_relative 'bim/export'
require_relative 'bim/solid'

module SU_MCP
  # Tools that change the model. Each of these runs inside a single
  # start_operation/commit_operation pair so one MCP call == one undo step.
  MUTATING_TOOLS = %w[
    create_component create_components delete_component transform_component set_material
    boolean_operation chamfer_edges fillet_edges
    create_mortise_tenon create_dovetail create_finger_joint
    eval_ruby
    mep_create_route mep_label mep_declare_storeys mep_build_solids
  ].freeze

  class Server
    DEFAULT_PORT   = 9876
    MAX_LINE_BYTES = 8 * 1024 * 1024 # guard against a client that never sends \n
    # Text results are clamped before they ever hit the socket: an unbounded
    # eval_ruby return value otherwise burns the caller's whole context window.
    MAX_RESULT_CHARS = (ENV['SKETCHUP_MCP_MAX_CHARS'] || 4000).to_i
    MAX_LIST_ITEMS   = (ENV['SKETCHUP_MCP_MAX_ITEMS'] || 100).to_i

    def initialize(port: nil)
      @host    = ENV['SKETCHUP_MCP_HOST'] || '127.0.0.1'
      @port    = (port || ENV['SKETCHUP_MCP_PORT'] || Prefs.get("port") || DEFAULT_PORT).to_i
      @server  = nil
      @running = false
      @timer_id = nil
      @clients = {} # socket => read buffer
      @debug   = !ENV['SKETCHUP_MCP_DEBUG'].to_s.empty?
      show_console if @debug
    end

    # The dialogs show the tail of this. The Ruby Console is closed unless
    # SKETCHUP_MCP_DEBUG is set, so without a buffer the last thing the server
    # said is unreadable from inside SketchUp.
    LOG_LINES = 40

    def log(msg)
      @log ||= []
      @log << { at: Time.now.strftime("%H:%M:%S"), text: msg.to_s }
      @log.shift while @log.size > LOG_LINES
      SKETCHUP_CONSOLE.write("MCP: #{msg}\n")
    rescue StandardError
      puts "MCP: #{msg}"
    end

    # Newest last, the way it reads in a console.
    def recent_log(count = 3)
      (@log || []).last(count)
    end

    def client_count
      @clients.size
    end

    # Set by the dialog layer. A window showing "0 kết nối" while a client is
    # talking is a window nobody can trust.
    attr_accessor :on_change

    def debug(msg)
      log(msg) if @debug
    end

    # The panel reads these; a failed start is otherwise only visible in the
    # Ruby Console, which is closed unless SKETCHUP_MCP_DEBUG is set.
    attr_reader :host, :port, :last_error

    # Settings can move the port, but only while nothing is bound to it — a
    # live change would leave the dialog advertising an address that is not
    # listening.
    def port=(value)
      raise "Tắt server trước khi đổi cổng" if @running

      @port = value.to_i
    end

    def running?
      @running
    end

    def start
      if @running
        log "Server already running on #{@host}:#{@port}"
        return
      end

      begin
        log "Starting server on #{@host}:#{@port}..."
        @last_error = nil
        @server  = TCPServer.new(@host, @port)
        @clients = {}
        @running = true

        @timer_id = UI.start_timer(0.1, true) { poll }

        log "Server listening on #{@host}:#{@port}"
      rescue StandardError => e
        @last_error = e.message
        log "Error starting server: #{e.message}"
        log e.backtrace.join("\n")
        stop
      end
    end

    def stop
      return unless @running || @server || @timer_id

      log "Stopping server..."
      @running = false

      if @timer_id
        UI.stop_timer(@timer_id)
        @timer_id = nil
      end

      @clients.each_key { |client| close_socket(client) }
      @clients = {}

      close_socket(@server) if @server
      @server = nil
      log "Server stopped"
    end

    private

    # Only forced open in debug mode. The extension used to pop the Ruby
    # Console on every SketchUp launch and then spam it with raw payloads.
    def show_console
      SKETCHUP_CONSOLE.show
    rescue StandardError
      begin
        Sketchup.send_action("showRubyPanel:")
      rescue StandardError
        nil
      end
    end

    # Runs on SketchUp's main thread every 0.1s, so nothing in here may block.
    # The old loop called client.gets — a blocking read that froze the whole UI
    # whenever a client connected without immediately sending a full line.
    def poll
      return unless @running

      accept_pending
      @clients.keys.each { |client| service(client) }
    rescue StandardError => e
      log "Poll error: #{e.message}"
      log e.backtrace.join("\n")
    end

    def accept_pending
      loop do
        client = @server.accept_nonblock
        client.sync = true if client.respond_to?(:sync=)
        @clients[client] = String.new
        debug "Client connected (#{@clients.size} open)"
        changed
      end
    rescue IO::WaitReadable, Errno::EAGAIN, Errno::EWOULDBLOCK
      # nothing else pending this tick
    rescue StandardError => e
      log "Accept error: #{e.message}"
    end

    def service(client)
      buffer = @clients[client]
      return unless buffer

      loop { buffer << client.read_nonblock(65_536) }
    rescue IO::WaitReadable, Errno::EAGAIN, Errno::EWOULDBLOCK
      drain_lines(client, buffer)
    rescue EOFError
      drain_lines(client, buffer)
      drop(client, "closed the connection")
    rescue Errno::ECONNRESET, Errno::EPIPE, IOError
      drop(client, "reset the connection")
    rescue StandardError => e
      log "Read error: #{e.message}"
      drop(client, "read error")
    end

    def drain_lines(client, buffer)
      while (idx = buffer.index("\n"))
        line = buffer.slice!(0, idx + 1).strip
        handle_line(client, line) unless line.empty?
        return unless @clients.key?(client)
      end

      return unless buffer.bytesize > MAX_LINE_BYTES

      log "Request exceeded #{MAX_LINE_BYTES} bytes with no newline"
      drop(client, "oversized request")
    end

    def handle_line(client, line)
      debug "-> #{truncate(line)}"

      request = nil
      response =
        begin
          request = JSON.parse(line)
          handle_jsonrpc_request(request)
        rescue JSON::ParserError => e
          log "JSON parse error: #{e.message}"
          error_response(nil, -32700, "Parse error")
        rescue StandardError => e
          log "Request error: #{e.message}"
          log e.backtrace.join("\n")
          error_response(request && request["id"], -32603, e.message)
        end

      write_response(client, response)
    end

    # The connection stays open across requests: the Python side keeps one
    # persistent socket, and closing after every response is what desynced it.
    def write_response(client, response)
      payload = response.to_json + "\n"
      debug "<- #{truncate(payload)}"
      client.write(payload)
      client.flush
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError => e
      drop(client, "write failed: #{e.message}")
    end

    def drop(client, reason)
      return unless @clients.delete(client)

      close_socket(client)
      debug "Client #{reason} (#{@clients.size} open)"
      changed
    end

    def changed
      @on_change&.call
    rescue StandardError => e
      log "Change notice failed: #{e.message}"
    end

    def close_socket(socket)
      socket.close
    rescue StandardError
      nil
    end

    def clamp(str, limit = MAX_RESULT_CHARS)
      return str if limit <= 0 || str.length <= limit

      "#{str[0, limit]}\n... [truncated #{str.length - limit} of #{str.length} chars]"
    end

    def truncate(str, limit = 500)
      str.length > limit ? "#{str[0, limit]}... (#{str.length} chars)" : str
    end

    def error_response(id, code, message)
      {
        jsonrpc: "2.0",
        error: { code: code, message: message, data: { success: false } },
        id: id
      }
    end

    def handle_jsonrpc_request(request)
      debug "method=#{request["method"] || request["command"]}"

      # Direct { "command": ..., "parameters": ... } form, kept for compatibility.
      if request["command"]
        return handle_tool_call(
          "jsonrpc" => request["jsonrpc"] || "2.0",
          "method"  => "tools/call",
          "params"  => { "name" => request["command"], "arguments" => request["parameters"] },
          "id"      => request["id"]
        )
      end

      case request["method"]
      when "tools/call"
        handle_tool_call(request)
      when "ping"
        { jsonrpc: request["jsonrpc"] || "2.0", result: { ok: true }, id: request["id"] }
      when "resources/list"
        {
          jsonrpc: request["jsonrpc"] || "2.0",
          result: { resources: list_resources, success: true },
          id: request["id"]
        }
      when "prompts/list"
        {
          jsonrpc: request["jsonrpc"] || "2.0",
          result: { prompts: [], success: true },
          id: request["id"]
        }
      else
        error_response(request["id"], -32601, "Method not found: #{request["method"]}")
      end
    end

    def list_resources
      model = Sketchup.active_model
      return [] unless model
      
      model.entities.first(MAX_LIST_ITEMS).map do |entity|
        { id: entity.entityID, type: entity.typename.downcase }
      end
    end

    def handle_tool_call(request)
      params    = request["params"] || {}
      tool_name = params["name"]
      args      = params["arguments"] || {}
      debug "tool=#{tool_name} args=#{truncate(args.inspect)}"

      begin
        result = with_operation(tool_name) { dispatch_tool(tool_name, args) }
        raise "Tool #{tool_name} reported failure" unless result.is_a?(Hash) && result[:success]

        {
          jsonrpc: request["jsonrpc"] || "2.0",
          result: {
            content: [{ type: "text", text: result_text(result) }],
            isError: false,
            success: true,
            resourceId: result[:id]
          },
          id: request["id"]
        }
      rescue StandardError => e
        log "Tool error (#{tool_name}): #{e.message}"
        debug e.backtrace.join("\n")
        error_response(request["id"], -32603, e.message)
      end
    end

    def dispatch_tool(tool_name, args)
      case tool_name
      when "create_component"     then create_component(args)
      when "create_components"    then create_components(args)
      when "delete_component"     then delete_component(args)
      when "transform_component"  then transform_component(args)
      when "get_selection", "get_selected_components" then get_selection
      when "get_scene_info"       then get_scene_info(args)
      when "export", "export_scene" then export_scene(args)
      when "set_material"         then set_material(args)
      when "boolean_operation"    then boolean_operation(args)
      when "chamfer_edges"        then chamfer_edges(args)
      when "fillet_edges"         then fillet_edges(args)
      when "create_mortise_tenon" then create_mortise_tenon(args)
      when "create_dovetail"      then create_dovetail(args)
      when "create_finger_joint"  then create_finger_joint(args)
      when "eval_ruby"            then eval_ruby(args)
      when "mep_create_route"     then mep_create_route(args)
      when "mep_label"            then mep_label(args)
      when "mep_declare_storeys"  then mep_declare_storeys(args)
      when "mep_unlabelled"       then mep_unlabelled
      when "mep_schedule"         then mep_schedule
      when "mep_export_schedule"  then mep_export_schedule(args)
      when "mep_build_solids"     then mep_build_solids
      else
        raise "Unknown tool: #{tool_name}"
      end
    end

    # One MCP call == one undo step. Without this, every add_face/pushpull lands
    # as its own entry and a generated model cannot be undone in one go; a
    # failure halfway through also left the partial geometry behind.
    def with_operation(tool_name)
      return yield unless MUTATING_TOOLS.include?(tool_name)

      model = Sketchup.active_model
      raise "No active model" unless model

      model.start_operation("MCP: #{tool_name}", true)
      begin
        result = yield
        model.commit_operation
        result
      rescue StandardError
        begin
          model.abort_operation
        rescue StandardError => abort_error
          log "abort_operation failed: #{abort_error.message}"
        end
        raise
      end
    end

    # Everything a tool returned (minus the :success flag) reaches the client.
    # The old code forwarded only result[:result], so get_selection dropped its
    # entity list and export_scene dropped the path it had just written.
    def result_text(result)
      payload = result.reject { |key, _| key == :success }
      return "Success" if payload.empty?
      return clamp(payload[:result].to_s) if payload.keys == [:result]

      payload.to_json
    end

    def create_component(params)
      log "Creating component with params: #{params.inspect}"
      model = Sketchup.active_model
      log "Got active model: #{model.inspect}"
      entities = model.active_entities
      log "Got active entities: #{entities.inspect}"
      
      pos = params["position"] || [0,0,0]
      dims = params["dimensions"] || [1,1,1]
      
      case params["type"]
      when "cube"
        log "Creating cube at position #{pos.inspect} with dimensions #{dims.inspect}"
        
        begin
          group = entities.add_group
          log "Created group: #{group.inspect}"
          
          face = group.entities.add_face(
            [pos[0], pos[1], pos[2]],
            [pos[0] + dims[0], pos[1], pos[2]],
            [pos[0] + dims[0], pos[1] + dims[1], pos[2]],
            [pos[0], pos[1] + dims[1], pos[2]]
          )
          log "Created face: #{face.inspect}"
          
          face.pushpull(dims[2])
          log "Pushed/pulled face by #{dims[2]}"
          
          result = { 
            id: group.entityID,
            success: true
          }
          log "Returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error in create_component: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      when "cylinder"
        log "Creating cylinder at position #{pos.inspect} with dimensions #{dims.inspect}"
        
        begin
          # Create a group to contain the cylinder
          group = entities.add_group
          
          # Extract dimensions
          radius = dims[0] / 2.0
          height = dims[2]
          
          # Create a circle at the base
          center = [pos[0] + radius, pos[1] + radius, pos[2]]
          
          # Create points for a circle
          num_segments = 24  # Number of segments for the circle
          circle_points = []
          
          num_segments.times do |i|
            angle = Math::PI * 2 * i / num_segments
            x = center[0] + radius * Math.cos(angle)
            y = center[1] + radius * Math.sin(angle)
            z = center[2]
            circle_points << [x, y, z]
          end
          
          # Create the circular face
          face = group.entities.add_face(circle_points)
          
          # Extrude the face to create the cylinder
          face.pushpull(height)
          
          result = { 
            id: group.entityID,
            success: true
          }
          log "Created cylinder, returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error creating cylinder: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      when "sphere"
        log "Creating sphere at position #{pos.inspect} with dimensions #{dims.inspect}"
        
        begin
          # Create a group to contain the sphere
          group = entities.add_group
          
          # Extract dimensions
          radius = dims[0] / 2.0
          center = [pos[0] + radius, pos[1] + radius, pos[2] + radius]
          
          # Use SketchUp's built-in sphere method if available
          if Sketchup::Tools.respond_to?(:create_sphere)
            Sketchup::Tools.create_sphere(center, radius, 24, group.entities)
          else
            # Fallback implementation using polygons
            # Create a UV sphere with latitude and longitude segments
            segments = 16
            
            # Create points for the sphere
            points = []
            for lat_i in 0..segments
              lat = Math::PI * lat_i / segments
              for lon_i in 0..segments
                lon = 2 * Math::PI * lon_i / segments
                x = center[0] + radius * Math.sin(lat) * Math.cos(lon)
                y = center[1] + radius * Math.sin(lat) * Math.sin(lon)
                z = center[2] + radius * Math.cos(lat)
                points << [x, y, z]
              end
            end
            
            # Create faces for the sphere (simplified approach)
            for lat_i in 0...segments
              for lon_i in 0...segments
                i1 = lat_i * (segments + 1) + lon_i
                i2 = i1 + 1
                i3 = i1 + segments + 1
                i4 = i3 + 1
                
                # Create a quad face
                begin
                  group.entities.add_face(points[i1], points[i2], points[i4], points[i3])
                rescue StandardError => e
                  # Skip faces that can't be created (may happen at poles)
                  log "Skipping face: #{e.message}"
                end
              end
            end
          end
          
          result = { 
            id: group.entityID,
            success: true
          }
          log "Created sphere, returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error creating sphere: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      when "cone"
        log "Creating cone at position #{pos.inspect} with dimensions #{dims.inspect}"
        
        begin
          # Create a group to contain the cone
          group = entities.add_group
          
          # Extract dimensions
          radius = dims[0] / 2.0
          height = dims[2]
          
          # Create a circle at the base
          center = [pos[0] + radius, pos[1] + radius, pos[2]]
          apex = [center[0], center[1], center[2] + height]
          
          # Create points for a circle
          num_segments = 24  # Number of segments for the circle
          circle_points = []
          
          num_segments.times do |i|
            angle = Math::PI * 2 * i / num_segments
            x = center[0] + radius * Math.cos(angle)
            y = center[1] + radius * Math.sin(angle)
            z = center[2]
            circle_points << [x, y, z]
          end
          
          # Create the circular face for the base
          base = group.entities.add_face(circle_points)
          
          # Create the cone sides
          (0...num_segments).each do |i|
            j = (i + 1) % num_segments
            # Create a triangular face from two adjacent points on the circle to the apex
            group.entities.add_face(circle_points[i], circle_points[j], apex)
          end
          
          result = { 
            id: group.entityID,
            success: true
          }
          log "Created cone, returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error creating cone: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      else
        raise "Unknown component type: #{params["type"]}"
      end
    end

    def delete_component(params)
      model = Sketchup.active_model
      
      # Handle ID format - strip quotes if present
      id_str = params["id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{id_str}"
      
      entity = model.find_entity_by_id(id_str.to_i)
      
      if entity
        log "Found entity: #{entity.inspect}"
        entity.erase!
        { success: true }
      else
        raise "Entity not found"
      end
    end

    def transform_component(params)
      model = Sketchup.active_model
      
      # Handle ID format - strip quotes if present
      id_str = params["id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{id_str}"
      
      entity = model.find_entity_by_id(id_str.to_i)
      
      if entity
        log "Found entity: #{entity.inspect}"
        
        # Handle position
        if params["position"]
          pos = params["position"]
          log "Transforming position to #{pos.inspect}"
          
          # Create a transformation to move the entity
          translation = Geom::Transformation.translation(Geom::Point3d.new(pos[0], pos[1], pos[2]))
          entity.transform!(translation)
        end
        
        # Handle rotation (in degrees)
        if params["rotation"]
          rot = params["rotation"]
          log "Rotating by #{rot.inspect} degrees"
          
          # Convert to radians
          x_rot = rot[0] * Math::PI / 180
          y_rot = rot[1] * Math::PI / 180
          z_rot = rot[2] * Math::PI / 180
          
          # Apply rotations
          if rot[0] != 0
            rotation = Geom::Transformation.rotation(entity.bounds.center, Geom::Vector3d.new(1, 0, 0), x_rot)
            entity.transform!(rotation)
          end
          
          if rot[1] != 0
            rotation = Geom::Transformation.rotation(entity.bounds.center, Geom::Vector3d.new(0, 1, 0), y_rot)
            entity.transform!(rotation)
          end
          
          if rot[2] != 0
            rotation = Geom::Transformation.rotation(entity.bounds.center, Geom::Vector3d.new(0, 0, 1), z_rot)
            entity.transform!(rotation)
          end
        end
        
        # Handle scale
        if params["scale"]
          scale = params["scale"]
          log "Scaling by #{scale.inspect}"
          
          # Create a transformation to scale the entity
          center = entity.bounds.center
          scaling = Geom::Transformation.scaling(center, scale[0], scale[1], scale[2])
          entity.transform!(scaling)
        end
        
        { success: true, id: entity.entityID }
      else
        raise "Entity not found"
      end
    end

    def get_selection
      model = Sketchup.active_model
      selection = model.selection
      
      log "Getting selection, count: #{selection.length}"
      
      selected_entities = selection.map do |entity|
        {
          id: entity.entityID,
          type: entity.typename.downcase
        }
      end
      
      { success: true, entities: selected_entities }
    end
    
    def export_scene(params)
      model  = Sketchup.active_model
      format = (params["format"] || "skp").to_s.downcase

      temp_dir = File.join(export_dir, "sketchup_exports")
      FileUtils.mkdir_p(temp_dir)
      filename = "sketchup_export_#{Time.now.strftime('%Y%m%d_%H%M%S')}"

      case format
      when "skp"
        export_path = File.join(temp_dir, "#{filename}.skp")
        raise "Failed to save .skp to #{export_path}" unless model.save(export_path)

      when "obj", "dae", "stl", "fbx", "3ds", "wrl", "xsi", "kmz"
        export_path = File.join(temp_dir, "#{filename}.#{format}")
        # model.export returns false when the exporter is missing — several of
        # them ship with Pro only. The old guard called Sketchup.require, which
        # returns false for an already-loaded file, so this branch always raised.
        unless model.export(export_path, exporter_options(format))
          raise "#{format.upcase} export failed - exporter not available in this SketchUp edition"
        end

      when "png", "jpg", "jpeg"
        ext = format == "jpg" ? "jpeg" : format
        export_path = File.join(temp_dir, "#{filename}.#{ext}")
        model.active_view.write_image(
          :filename    => export_path,
          :width       => (params["width"] || 1920).to_i,
          :height      => (params["height"] || 1080).to_i,
          :antialias   => true,
          :transparent => (ext == "png")
        )

      else
        raise "Unsupported export format: #{format}"
      end

      raise "Exporter reported success but #{export_path} is missing" unless File.exist?(export_path)

      log "Exported #{format} to #{export_path}"
      { success: true, path: export_path, format: format, bytes: File.size(export_path) }
    rescue StandardError => e
      log "Error in export_scene: #{e.message}"
      debug e.backtrace.join("\n")
      raise
    end

    def exporter_options(format)
      case format
      when "obj"
        { :triangulated_faces => true, :double_sided_faces => true,
          :edges => false, :texture_maps => true }
      when "dae" then { :triangulated_faces => true, :edges => false }
      when "stl" then { :units => "model" }
      else {}
      end
    end

    # TEMP/TMP are unset on macOS, and Dir.tmpdir needs 'tmpdir' required —
    # the old lookup raised NameError before it ever reached a fallback.
    def export_dir
      ENV['SKETCHUP_MCP_EXPORT_DIR'] || ENV['TMPDIR'] || ENV['TEMP'] || ENV['TMP'] || Dir.tmpdir
    end

    # Summary by default. Listing every entity with its bounds on a real model
    # is thousands of tokens the caller almost never needs, so bounds are
    # opt-in and the entity list is capped.
    def get_scene_info(params = {})
      model = Sketchup.active_model
      raise "No active model" unless model

      detail = [true, "true", 1, "1"].include?(params["detail"])
      limit  = (params["limit"] || MAX_LIST_ITEMS).to_i
      limit  = MAX_LIST_ITEMS if limit <= 0

      top_level = model.entities.select { |entity|
        entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
      }

      bounds = model.bounds
      info = {
        success: true,
        name: model.title.to_s.empty? ? "Untitled" : model.title,
        path: model.path.to_s,
        units: model_units,
        entity_count: model.entities.length,
        group_count: top_level.length,
        selection_count: model.selection.length,
        layer_count: model.layers.length,
        material_count: model.materials.length,
        bounds: { min: bounds.min.to_a.map(&:to_f), max: bounds.max.to_a.map(&:to_f) },
        entities: top_level.first(limit).map { |entity| entity_summary(entity, detail) }
      }
      info[:entities_omitted] = top_level.length - limit if top_level.length > limit

      if detail
        info[:layers]    = model.layers.map(&:name)
        info[:materials] = model.materials.map(&:name)
      end

      info
    end

    def entity_summary(entity, detail = false)
      info = { id: entity.entityID, type: entity.typename.downcase }
      info[:name] = entity.name unless entity.name.to_s.empty?
      info[:definition] = entity.definition.name if entity.is_a?(Sketchup::ComponentInstance)
      if detail && entity.respond_to?(:bounds)
        box = entity.bounds
        info[:bounds] = { min: box.min.to_a.map(&:to_f), max: box.max.to_a.map(&:to_f) }
      end
      info
    end

    # One round trip, one undo step, N primitives. Building a model through
    # create_component one shape at a time costs a full request/response pair
    # (and a full tool-result payload) per box.
    def create_components(params)
      specs = params["components"]
      raise "create_components expects a 'components' array" unless specs.is_a?(Array)
      raise "create_components got an empty list" if specs.empty?

      ids = specs.each_with_index.map do |spec, index|
        begin
          result = create_component(spec)
          result[:id]
        rescue StandardError => e
          raise "component #{index} (#{spec.inspect}) failed: #{e.message}"
        end
      end

      { success: true, ids: ids, count: ids.length }
    end

    # Geometry values are always inches regardless of this setting; it is
    # reported so the caller knows what the user sees in Model Info.
    def model_units
      index = begin
        Sketchup.active_model.options["UnitsOptions"]["LengthUnit"]
      rescue StandardError
        0
      end
      %w[inches feet millimeters centimeters meters][index.to_i] || "inches"
    end
    
    def set_material(params)
      log "Setting material with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Handle ID format - strip quotes if present
      id_str = params["id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{id_str}"
      
      entity = model.find_entity_by_id(id_str.to_i)
      
      if entity
        log "Found entity: #{entity.inspect}"
        
        material_name = params["material"]
        log "Setting material to: #{material_name}"
        
        # Get or create the material
        material = model.materials[material_name]
        if !material
          # Create a new material if it doesn't exist
          material = model.materials.add(material_name)
          
          # Handle color specification
          case material_name.downcase
          when "red"
            material.color = Sketchup::Color.new(255, 0, 0)
          when "green"
            material.color = Sketchup::Color.new(0, 255, 0)
          when "blue"
            material.color = Sketchup::Color.new(0, 0, 255)
          when "yellow"
            material.color = Sketchup::Color.new(255, 255, 0)
          when "cyan", "turquoise"
            material.color = Sketchup::Color.new(0, 255, 255)
          when "magenta", "purple"
            material.color = Sketchup::Color.new(255, 0, 255)
          when "white"
            material.color = Sketchup::Color.new(255, 255, 255)
          when "black"
            material.color = Sketchup::Color.new(0, 0, 0)
          when "brown"
            material.color = Sketchup::Color.new(139, 69, 19)
          when "orange"
            material.color = Sketchup::Color.new(255, 165, 0)
          when "gray", "grey"
            material.color = Sketchup::Color.new(128, 128, 128)
          else
            # If it's a hex color code like "#FF0000"
            if material_name.start_with?("#") && material_name.length == 7
              begin
                r = material_name[1..2].to_i(16)
                g = material_name[3..4].to_i(16)
                b = material_name[5..6].to_i(16)
                material.color = Sketchup::Color.new(r, g, b)
              rescue
                # Default to a wood color if parsing fails
                material.color = Sketchup::Color.new(184, 134, 72)
              end
            else
              # Default to a wood color
              material.color = Sketchup::Color.new(184, 134, 72)
            end
          end
        end
        
        # Apply the material to the entity
        if entity.respond_to?(:material=)
          entity.material = material
        elsif entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          # For groups and components, we need to apply to all faces
          entities = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
          entities.grep(Sketchup::Face).each { |face| face.material = material }
        end
        
        { success: true, id: entity.entityID }
      else
        raise "Entity not found"
      end
    end
    
    def boolean_operation(params)
      log "Performing boolean operation with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get operation type
      operation_type = params["operation"]
      unless ["union", "difference", "intersection"].include?(operation_type)
        raise "Invalid boolean operation: #{operation_type}. Must be 'union', 'difference', or 'intersection'."
      end
      
      # Get target and tool entities
      target_id = params["target_id"].to_s.gsub('"', '')
      tool_id = params["tool_id"].to_s.gsub('"', '')
      
      log "Looking for target entity with ID: #{target_id}"
      target_entity = model.find_entity_by_id(target_id.to_i)
      
      log "Looking for tool entity with ID: #{tool_id}"
      tool_entity = model.find_entity_by_id(tool_id.to_i)
      
      unless target_entity && tool_entity
        missing = []
        missing << "target" unless target_entity
        missing << "tool" unless tool_entity
        raise "Entity not found: #{missing.join(', ')}"
      end
      
      # Ensure both entities are groups or component instances
      unless (target_entity.is_a?(Sketchup::Group) || target_entity.is_a?(Sketchup::ComponentInstance)) &&
             (tool_entity.is_a?(Sketchup::Group) || tool_entity.is_a?(Sketchup::ComponentInstance))
        raise "Boolean operations require groups or component instances"
      end
      
      # Create a new group to hold the result
      result_group = model.active_entities.add_group
      
      # Perform the boolean operation
      case operation_type
      when "union"
        log "Performing union operation"
        perform_union(target_entity, tool_entity, result_group)
      when "difference"
        log "Performing difference operation"
        perform_difference(target_entity, tool_entity, result_group)
      when "intersection"
        log "Performing intersection operation"
        perform_intersection(target_entity, tool_entity, result_group)
      end
      
      # Clean up original entities if requested
      if params["delete_originals"]
        target_entity.erase! if target_entity.valid?
        tool_entity.erase! if tool_entity.valid?
      end
      
      # Return the result
      { 
        success: true, 
        id: result_group.entityID
      }
    end
    
    def perform_union(target, tool, result_group)
      model = Sketchup.active_model
      
      # Create temporary copies of the target and tool
      target_copy = target.copy
      tool_copy = tool.copy
      
      # Get the transformation of each entity
      target_transform = target.transformation
      tool_transform = tool.transformation
      
      # Apply the transformations to the copies
      target_copy.transform!(target_transform)
      tool_copy.transform!(tool_transform)
      
      # Get the entities from the copies
      target_entities = target_copy.is_a?(Sketchup::Group) ? target_copy.entities : target_copy.definition.entities
      tool_entities = tool_copy.is_a?(Sketchup::Group) ? tool_copy.entities : tool_copy.definition.entities
      
      # Copy all entities from target to result
      target_entities.each do |entity|
        entity.copy(result_group.entities)
      end
      
      # Copy all entities from tool to result
      tool_entities.each do |entity|
        entity.copy(result_group.entities)
      end
      
      # Clean up temporary copies
      target_copy.erase!
      tool_copy.erase!
      
      # Outer shell - this will merge overlapping geometry
      result_group.entities.outer_shell
    end
    
    def perform_difference(target, tool, result_group)
      model = Sketchup.active_model
      
      # Create temporary copies of the target and tool
      target_copy = target.copy
      tool_copy = tool.copy
      
      # Get the transformation of each entity
      target_transform = target.transformation
      tool_transform = tool.transformation
      
      # Apply the transformations to the copies
      target_copy.transform!(target_transform)
      tool_copy.transform!(tool_transform)
      
      # Get the entities from the copies
      target_entities = target_copy.is_a?(Sketchup::Group) ? target_copy.entities : target_copy.definition.entities
      tool_entities = tool_copy.is_a?(Sketchup::Group) ? tool_copy.entities : tool_copy.definition.entities
      
      # Copy all entities from target to result
      target_entities.each do |entity|
        entity.copy(result_group.entities)
      end
      
      # Create a temporary group for the tool
      temp_tool_group = model.active_entities.add_group
      
      # Copy all entities from tool to temp group
      tool_entities.each do |entity|
        entity.copy(temp_tool_group.entities)
      end
      
      # Subtract the tool from the result
      result_group.entities.subtract(temp_tool_group.entities)
      
      # Clean up temporary copies and groups
      target_copy.erase!
      tool_copy.erase!
      temp_tool_group.erase!
    end
    
    def perform_intersection(target, tool, result_group)
      model = Sketchup.active_model
      
      # Create temporary copies of the target and tool
      target_copy = target.copy
      tool_copy = tool.copy
      
      # Get the transformation of each entity
      target_transform = target.transformation
      tool_transform = tool.transformation
      
      # Apply the transformations to the copies
      target_copy.transform!(target_transform)
      tool_copy.transform!(tool_transform)
      
      # Get the entities from the copies
      target_entities = target_copy.is_a?(Sketchup::Group) ? target_copy.entities : target_copy.definition.entities
      tool_entities = tool_copy.is_a?(Sketchup::Group) ? tool_copy.entities : tool_copy.definition.entities
      
      # Create temporary groups for target and tool
      temp_target_group = model.active_entities.add_group
      temp_tool_group = model.active_entities.add_group
      
      # Copy all entities from target and tool to temp groups
      target_entities.each do |entity|
        entity.copy(temp_target_group.entities)
      end
      
      tool_entities.each do |entity|
        entity.copy(temp_tool_group.entities)
      end
      
      # Perform the intersection
      result_group.entities.intersect_with(temp_target_group.entities, temp_tool_group.entities)
      
      # Clean up temporary copies and groups
      target_copy.erase!
      tool_copy.erase!
      temp_target_group.erase!
      temp_tool_group.erase!
    end
    
    def chamfer_edges(params)
      log "Chamfering edges with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get entity ID
      entity_id = params["entity_id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{entity_id}"
      
      entity = model.find_entity_by_id(entity_id.to_i)
      unless entity
        raise "Entity not found: #{entity_id}"
      end
      
      # Ensure entity is a group or component instance
      unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        raise "Chamfer operation requires a group or component instance"
      end
      
      # Get the distance parameter
      distance = params["distance"] || 0.5
      
      # Get the entities collection
      entities = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
      
      # Find all edges in the entity
      edges = entities.grep(Sketchup::Edge)
      
      # If specific edges are provided, filter the edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        edges = edges.select.with_index { |_, i| edge_indices.include?(i) }
      end
      
      # Create a new group to hold the result
      result_group = model.active_entities.add_group
      
      # Copy all entities from the original to the result
      entities.each do |e|
        e.copy(result_group.entities)
      end
      
      # Get the edges in the result group
      result_edges = result_group.entities.grep(Sketchup::Edge)
      
      # If specific edges were provided, filter the result edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        result_edges = result_edges.select.with_index { |_, i| edge_indices.include?(i) }
      end
      
      # Perform the chamfer operation
      begin
        # Create a transformation for the chamfer
        chamfer_transform = Geom::Transformation.scaling(1.0 - distance)
        
        # For each edge, create a chamfer
        result_edges.each do |edge|
          # Get the faces connected to this edge
          faces = edge.faces
          next if faces.length < 2
          
          # Get the start and end points of the edge
          start_point = edge.start.position
          end_point = edge.end.position
          
          # Calculate the midpoint of the edge
          midpoint = Geom::Point3d.new(
            (start_point.x + end_point.x) / 2.0,
            (start_point.y + end_point.y) / 2.0,
            (start_point.z + end_point.z) / 2.0
          )
          
          # Create a chamfer by creating a new face
          # This is a simplified approach - in a real implementation,
          # you would need to handle various edge cases
          new_points = []
          
          # For each vertex of the edge
          [edge.start, edge.end].each do |vertex|
            # Get all edges connected to this vertex
            connected_edges = vertex.edges - [edge]
            
            # For each connected edge
            connected_edges.each do |connected_edge|
              # Get the other vertex of the connected edge
              other_vertex = (connected_edge.vertices - [vertex])[0]
              
              # Calculate a point along the connected edge
              direction = other_vertex.position - vertex.position
              new_point = vertex.position.offset(direction, distance)
              
              new_points << new_point
            end
          end
          
          # Create a new face using the new points
          if new_points.length >= 3
            result_group.entities.add_face(new_points)
          end
        end
        
        # Clean up the original entity if requested
        if params["delete_original"]
          entity.erase! if entity.valid?
        end
        
        # Return the result
        { 
          success: true, 
          id: result_group.entityID
        }
      rescue StandardError => e
        log "Error in chamfer_edges: #{e.message}"
        log e.backtrace.join("\n")
        
        # Clean up the result group if there was an error
        result_group.erase! if result_group.valid?
        
        raise
      end
    end
    
    def fillet_edges(params)
      log "Filleting edges with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get entity ID
      entity_id = params["entity_id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{entity_id}"
      
      entity = model.find_entity_by_id(entity_id.to_i)
      unless entity
        raise "Entity not found: #{entity_id}"
      end
      
      # Ensure entity is a group or component instance
      unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        raise "Fillet operation requires a group or component instance"
      end
      
      # Get the radius parameter
      radius = params["radius"] || 0.5
      
      # Get the number of segments for the fillet
      segments = params["segments"] || 8
      
      # Get the entities collection
      entities = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
      
      # Find all edges in the entity
      edges = entities.grep(Sketchup::Edge)
      
      # If specific edges are provided, filter the edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        edges = edges.select.with_index { |_, i| edge_indices.include?(i) }
      end
      
      # Create a new group to hold the result
      result_group = model.active_entities.add_group
      
      # Copy all entities from the original to the result
      entities.each do |e|
        e.copy(result_group.entities)
      end
      
      # Get the edges in the result group
      result_edges = result_group.entities.grep(Sketchup::Edge)
      
      # If specific edges were provided, filter the result edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        result_edges = result_edges.select.with_index { |_, i| edge_indices.include?(i) }
      end
      
      # Perform the fillet operation
      begin
        # For each edge, create a fillet
        result_edges.each do |edge|
          # Get the faces connected to this edge
          faces = edge.faces
          next if faces.length < 2
          
          # Get the start and end points of the edge
          start_point = edge.start.position
          end_point = edge.end.position
          
          # Calculate the midpoint of the edge
          midpoint = Geom::Point3d.new(
            (start_point.x + end_point.x) / 2.0,
            (start_point.y + end_point.y) / 2.0,
            (start_point.z + end_point.z) / 2.0
          )
          
          # Calculate the edge vector
          edge_vector = end_point - start_point
          edge_length = edge_vector.length
          
          # Create points for the fillet curve
          fillet_points = []
          
          # Create a series of points along a circular arc
          (0..segments).each do |i|
            angle = Math::PI * i / segments
            
            # Calculate the point on the arc
            x = midpoint.x + radius * Math.cos(angle)
            y = midpoint.y + radius * Math.sin(angle)
            z = midpoint.z
            
            fillet_points << Geom::Point3d.new(x, y, z)
          end
          
          # Create edges connecting the fillet points
          (0...fillet_points.length - 1).each do |i|
            result_group.entities.add_line(fillet_points[i], fillet_points[i+1])
          end
          
          # Create a face from the fillet points
          if fillet_points.length >= 3
            result_group.entities.add_face(fillet_points)
          end
        end
        
        # Clean up the original entity if requested
        if params["delete_original"]
          entity.erase! if entity.valid?
        end
        
        # Return the result
        { 
          success: true, 
          id: result_group.entityID
        }
      rescue StandardError => e
        log "Error in fillet_edges: #{e.message}"
        log e.backtrace.join("\n")
        
        # Clean up the result group if there was an error
        result_group.erase! if result_group.valid?
        
        raise
      end
    end
    
    def create_mortise_tenon(params)
      log "Creating mortise and tenon joint with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get the mortise and tenon board IDs
      mortise_id = params["mortise_id"].to_s.gsub('"', '')
      tenon_id = params["tenon_id"].to_s.gsub('"', '')
      
      log "Looking for mortise board with ID: #{mortise_id}"
      mortise_board = model.find_entity_by_id(mortise_id.to_i)
      
      log "Looking for tenon board with ID: #{tenon_id}"
      tenon_board = model.find_entity_by_id(tenon_id.to_i)
      
      unless mortise_board && tenon_board
        missing = []
        missing << "mortise board" unless mortise_board
        missing << "tenon board" unless tenon_board
        raise "Entity not found: #{missing.join(', ')}"
      end
      
      # Ensure both entities are groups or component instances
      unless (mortise_board.is_a?(Sketchup::Group) || mortise_board.is_a?(Sketchup::ComponentInstance)) &&
             (tenon_board.is_a?(Sketchup::Group) || tenon_board.is_a?(Sketchup::ComponentInstance))
        raise "Mortise and tenon operation requires groups or component instances"
      end
      
      # Get joint parameters
      width = params["width"] || 1.0
      height = params["height"] || 1.0
      depth = params["depth"] || 1.0
      offset_x = params["offset_x"] || 0.0
      offset_y = params["offset_y"] || 0.0
      offset_z = params["offset_z"] || 0.0
      
      # Get the bounds of both boards
      mortise_bounds = mortise_board.bounds
      tenon_bounds = tenon_board.bounds
      
      # Determine the face to place the joint on based on the relative positions of the boards
      mortise_center = mortise_bounds.center
      tenon_center = tenon_bounds.center
      
      # Calculate the direction vector from mortise to tenon
      direction_vector = tenon_center - mortise_center
      
      # Determine which face of the mortise board is closest to the tenon board
      mortise_face_direction = determine_closest_face(direction_vector)
      
      # Create the mortise (hole) in the mortise board
      mortise_result = create_mortise(
        mortise_board, 
        width, 
        height, 
        depth, 
        mortise_face_direction,
        mortise_bounds,
        offset_x, 
        offset_y, 
        offset_z
      )
      
      # Determine which face of the tenon board is closest to the mortise board
      tenon_face_direction = determine_closest_face(direction_vector.reverse)
      
      # Create the tenon (projection) on the tenon board
      tenon_result = create_tenon(
        tenon_board, 
        width, 
        height, 
        depth, 
        tenon_face_direction,
        tenon_bounds,
        offset_x, 
        offset_y, 
        offset_z
      )
      
      # Return the result
      { 
        success: true, 
        mortise_id: mortise_result[:id],
        tenon_id: tenon_result[:id]
      }
    end
    
    def determine_closest_face(direction_vector)
      # Normalize the direction vector
      direction_vector.normalize!
      
      # Determine which axis has the largest component
      x_abs = direction_vector.x.abs
      y_abs = direction_vector.y.abs
      z_abs = direction_vector.z.abs
      
      if x_abs >= y_abs && x_abs >= z_abs
        # X-axis is dominant
        return direction_vector.x > 0 ? :east : :west
      elsif y_abs >= x_abs && y_abs >= z_abs
        # Y-axis is dominant
        return direction_vector.y > 0 ? :north : :south
      else
        # Z-axis is dominant
        return direction_vector.z > 0 ? :top : :bottom
      end
    end
    
    def create_mortise(board, width, height, depth, face_direction, bounds, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      
      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities
      
      # Calculate the position of the mortise based on the face direction
      mortise_position = calculate_position_on_face(face_direction, bounds, width, height, depth, offset_x, offset_y, offset_z)
      
      log "Creating mortise at position: #{mortise_position.inspect} with dimensions: #{[width, height, depth].inspect}"
      
      # Create a box for the mortise
      mortise_group = entities.add_group
      
      # Create the mortise box with the correct orientation
      case face_direction
      when :east, :west
        # Mortise on east or west face (YZ plane)
        mortise_face = mortise_group.entities.add_face(
          [mortise_position[0], mortise_position[1], mortise_position[2]],
          [mortise_position[0], mortise_position[1] + width, mortise_position[2]],
          [mortise_position[0], mortise_position[1] + width, mortise_position[2] + height],
          [mortise_position[0], mortise_position[1], mortise_position[2] + height]
        )
        mortise_face.pushpull(face_direction == :east ? -depth : depth)
      when :north, :south
        # Mortise on north or south face (XZ plane)
        mortise_face = mortise_group.entities.add_face(
          [mortise_position[0], mortise_position[1], mortise_position[2]],
          [mortise_position[0] + width, mortise_position[1], mortise_position[2]],
          [mortise_position[0] + width, mortise_position[1], mortise_position[2] + height],
          [mortise_position[0], mortise_position[1], mortise_position[2] + height]
        )
        mortise_face.pushpull(face_direction == :north ? -depth : depth)
      when :top, :bottom
        # Mortise on top or bottom face (XY plane)
        mortise_face = mortise_group.entities.add_face(
          [mortise_position[0], mortise_position[1], mortise_position[2]],
          [mortise_position[0] + width, mortise_position[1], mortise_position[2]],
          [mortise_position[0] + width, mortise_position[1] + height, mortise_position[2]],
          [mortise_position[0], mortise_position[1] + height, mortise_position[2]]
        )
        mortise_face.pushpull(face_direction == :top ? -depth : depth)
      end
      
      # Subtract the mortise from the board
      entities.subtract(mortise_group.entities)
      
      # Clean up the temporary group
      mortise_group.erase!
      
      # Return the result
      { 
        success: true, 
        id: board.entityID
      }
    end
    
    def create_tenon(board, width, height, depth, face_direction, bounds, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      
      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities
      
      # Calculate the position of the tenon based on the face direction
      tenon_position = calculate_position_on_face(face_direction, bounds, width, height, depth, offset_x, offset_y, offset_z)
      
      log "Creating tenon at position: #{tenon_position.inspect} with dimensions: #{[width, height, depth].inspect}"
      
      # Create a box for the tenon
      tenon_group = model.active_entities.add_group
      
      # Create the tenon box with the correct orientation
      case face_direction
      when :east, :west
        # Tenon on east or west face (YZ plane)
        tenon_face = tenon_group.entities.add_face(
          [tenon_position[0], tenon_position[1], tenon_position[2]],
          [tenon_position[0], tenon_position[1] + width, tenon_position[2]],
          [tenon_position[0], tenon_position[1] + width, tenon_position[2] + height],
          [tenon_position[0], tenon_position[1], tenon_position[2] + height]
        )
        tenon_face.pushpull(face_direction == :east ? depth : -depth)
      when :north, :south
        # Tenon on north or south face (XZ plane)
        tenon_face = tenon_group.entities.add_face(
          [tenon_position[0], tenon_position[1], tenon_position[2]],
          [tenon_position[0] + width, tenon_position[1], tenon_position[2]],
          [tenon_position[0] + width, tenon_position[1], tenon_position[2] + height],
          [tenon_position[0], tenon_position[1], tenon_position[2] + height]
        )
        tenon_face.pushpull(face_direction == :north ? depth : -depth)
      when :top, :bottom
        # Tenon on top or bottom face (XY plane)
        tenon_face = tenon_group.entities.add_face(
          [tenon_position[0], tenon_position[1], tenon_position[2]],
          [tenon_position[0] + width, tenon_position[1], tenon_position[2]],
          [tenon_position[0] + width, tenon_position[1] + height, tenon_position[2]],
          [tenon_position[0], tenon_position[1] + height, tenon_position[2]]
        )
        tenon_face.pushpull(face_direction == :top ? depth : -depth)
      end
      
      # Get the transformation of the board
      board_transform = board.transformation
      
      # Apply the inverse transformation to the tenon group
      tenon_group.transform!(board_transform.inverse)
      
      # Union the tenon with the board
      board_entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities
      board_entities.add_instance(tenon_group.entities.parent, Geom::Transformation.new)
      
      # Clean up the temporary group
      tenon_group.erase!
      
      # Return the result
      { 
        success: true, 
        id: board.entityID
      }
    end
    
    def calculate_position_on_face(face_direction, bounds, width, height, depth, offset_x, offset_y, offset_z)
      # Calculate the position on the specified face with offsets
      case face_direction
      when :east
        # Position on the east face (max X)
        [
          bounds.max.x,
          bounds.center.y - width/2 + offset_y,
          bounds.center.z - height/2 + offset_z
        ]
      when :west
        # Position on the west face (min X)
        [
          bounds.min.x,
          bounds.center.y - width/2 + offset_y,
          bounds.center.z - height/2 + offset_z
        ]
      when :north
        # Position on the north face (max Y)
        [
          bounds.center.x - width/2 + offset_x,
          bounds.max.y,
          bounds.center.z - height/2 + offset_z
        ]
      when :south
        # Position on the south face (min Y)
        [
          bounds.center.x - width/2 + offset_x,
          bounds.min.y,
          bounds.center.z - height/2 + offset_z
        ]
      when :top
        # Position on the top face (max Z)
        [
          bounds.center.x - width/2 + offset_x,
          bounds.center.y - height/2 + offset_y,
          bounds.max.z
        ]
      when :bottom
        # Position on the bottom face (min Z)
        [
          bounds.center.x - width/2 + offset_x,
          bounds.center.y - height/2 + offset_y,
          bounds.min.z
        ]
      end
    end
    
    def create_dovetail(params)
      log "Creating dovetail joint with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get the tail and pin board IDs
      tail_id = params["tail_id"].to_s.gsub('"', '')
      pin_id = params["pin_id"].to_s.gsub('"', '')
      
      log "Looking for tail board with ID: #{tail_id}"
      tail_board = model.find_entity_by_id(tail_id.to_i)
      
      log "Looking for pin board with ID: #{pin_id}"
      pin_board = model.find_entity_by_id(pin_id.to_i)
      
      unless tail_board && pin_board
        missing = []
        missing << "tail board" unless tail_board
        missing << "pin board" unless pin_board
        raise "Entity not found: #{missing.join(', ')}"
      end
      
      # Ensure both entities are groups or component instances
      unless (tail_board.is_a?(Sketchup::Group) || tail_board.is_a?(Sketchup::ComponentInstance)) &&
             (pin_board.is_a?(Sketchup::Group) || pin_board.is_a?(Sketchup::ComponentInstance))
        raise "Dovetail operation requires groups or component instances"
      end
      
      # Get joint parameters
      width = params["width"] || 1.0
      height = params["height"] || 2.0
      depth = params["depth"] || 1.0
      angle = params["angle"] || 15.0  # Dovetail angle in degrees
      num_tails = params["num_tails"] || 3
      offset_x = params["offset_x"] || 0.0
      offset_y = params["offset_y"] || 0.0
      offset_z = params["offset_z"] || 0.0
      
      # Create the tails on the tail board
      tail_result = create_tails(tail_board, width, height, depth, angle, num_tails, offset_x, offset_y, offset_z)
      
      # Create the pins on the pin board
      pin_result = create_pins(pin_board, width, height, depth, angle, num_tails, offset_x, offset_y, offset_z)
      
      # Return the result
      { 
        success: true, 
        tail_id: tail_result[:id],
        pin_id: pin_result[:id]
      }
    end
    
    def create_tails(board, width, height, depth, angle, num_tails, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      
      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities
      
      # Get the board's bounds
      bounds = board.bounds
      
      # Calculate the position of the dovetail joint
      center_x = bounds.center.x + offset_x
      center_y = bounds.center.y + offset_y
      center_z = bounds.center.z + offset_z
      
      # Calculate the width of each tail and space
      total_width = width
      tail_width = total_width / (2 * num_tails - 1)
      
      # Create a group for the tails
      tails_group = entities.add_group
      
      # Create each tail
      num_tails.times do |i|
        # Calculate the position of this tail
        tail_center_x = center_x - width/2 + tail_width * (2 * i)
        
        # Calculate the dovetail shape
        angle_rad = angle * Math::PI / 180.0
        tail_top_width = tail_width
        tail_bottom_width = tail_width + 2 * depth * Math.tan(angle_rad)
        
        # Create the tail shape
        tail_points = [
          [tail_center_x - tail_top_width/2, center_y - height/2, center_z],
          [tail_center_x + tail_top_width/2, center_y - height/2, center_z],
          [tail_center_x + tail_bottom_width/2, center_y - height/2, center_z - depth],
          [tail_center_x - tail_bottom_width/2, center_y - height/2, center_z - depth]
        ]
        
        # Create the tail face
        tail_face = tails_group.entities.add_face(tail_points)
        
        # Extrude the tail
        tail_face.pushpull(height)
      end
      
      # Return the result
      { 
        success: true, 
        id: board.entityID
      }
    end
    
    def create_pins(board, width, height, depth, angle, num_tails, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      
      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities
      
      # Get the board's bounds
      bounds = board.bounds
      
      # Calculate the position of the dovetail joint
      center_x = bounds.center.x + offset_x
      center_y = bounds.center.y + offset_y
      center_z = bounds.center.z + offset_z
      
      # Calculate the width of each tail and space
      total_width = width
      tail_width = total_width / (2 * num_tails - 1)
      
      # Create a group for the pins
      pins_group = entities.add_group
      
      # Create a box for the entire pin area
      pin_area_face = pins_group.entities.add_face(
        [center_x - width/2, center_y - height/2, center_z],
        [center_x + width/2, center_y - height/2, center_z],
        [center_x + width/2, center_y + height/2, center_z],
        [center_x - width/2, center_y + height/2, center_z]
      )
      
      # Extrude the pin area
      pin_area_face.pushpull(depth)
      
      # Create each tail cutout
      num_tails.times do |i|
        # Calculate the position of this tail
        tail_center_x = center_x - width/2 + tail_width * (2 * i)
        
        # Calculate the dovetail shape
        angle_rad = angle * Math::PI / 180.0
        tail_top_width = tail_width
        tail_bottom_width = tail_width + 2 * depth * Math.tan(angle_rad)
        
        # Create a group for the tail cutout
        tail_cutout_group = entities.add_group
        
        # Create the tail cutout shape
        tail_points = [
          [tail_center_x - tail_top_width/2, center_y - height/2, center_z],
          [tail_center_x + tail_top_width/2, center_y - height/2, center_z],
          [tail_center_x + tail_bottom_width/2, center_y - height/2, center_z - depth],
          [tail_center_x - tail_bottom_width/2, center_y - height/2, center_z - depth]
        ]
        
        # Create the tail cutout face
        tail_face = tail_cutout_group.entities.add_face(tail_points)
        
        # Extrude the tail cutout
        tail_face.pushpull(height)
        
        # Subtract the tail cutout from the pin area
        pins_group.entities.subtract(tail_cutout_group.entities)
        
        # Clean up the temporary group
        tail_cutout_group.erase!
      end
      
      # Return the result
      { 
        success: true, 
        id: board.entityID
      }
    end
    
    def create_finger_joint(params)
      log "Creating finger joint with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get the two board IDs
      board1_id = params["board1_id"].to_s.gsub('"', '')
      board2_id = params["board2_id"].to_s.gsub('"', '')
      
      log "Looking for board 1 with ID: #{board1_id}"
      board1 = model.find_entity_by_id(board1_id.to_i)
      
      log "Looking for board 2 with ID: #{board2_id}"
      board2 = model.find_entity_by_id(board2_id.to_i)
      
      unless board1 && board2
        missing = []
        missing << "board 1" unless board1
        missing << "board 2" unless board2
        raise "Entity not found: #{missing.join(', ')}"
      end
      
      # Ensure both entities are groups or component instances
      unless (board1.is_a?(Sketchup::Group) || board1.is_a?(Sketchup::ComponentInstance)) &&
             (board2.is_a?(Sketchup::Group) || board2.is_a?(Sketchup::ComponentInstance))
        raise "Finger joint operation requires groups or component instances"
      end
      
      # Get joint parameters
      width = params["width"] || 1.0
      height = params["height"] || 2.0
      depth = params["depth"] || 1.0
      num_fingers = params["num_fingers"] || 5
      offset_x = params["offset_x"] || 0.0
      offset_y = params["offset_y"] || 0.0
      offset_z = params["offset_z"] || 0.0
      
      # Create the fingers on board 1
      board1_result = create_board1_fingers(board1, width, height, depth, num_fingers, offset_x, offset_y, offset_z)
      
      # Create the matching slots on board 2
      board2_result = create_board2_slots(board2, width, height, depth, num_fingers, offset_x, offset_y, offset_z)
      
      # Return the result
      { 
        success: true, 
        board1_id: board1_result[:id],
        board2_id: board2_result[:id]
      }
    end
    
    def create_board1_fingers(board, width, height, depth, num_fingers, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      
      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities
      
      # Get the board's bounds
      bounds = board.bounds
      
      # Calculate the position of the joint
      center_x = bounds.center.x + offset_x
      center_y = bounds.center.y + offset_y
      center_z = bounds.center.z + offset_z
      
      # Calculate the width of each finger
      finger_width = width / num_fingers
      
      # Create a group for the fingers
      fingers_group = entities.add_group
      
      # Create a base rectangle for the joint area
      base_face = fingers_group.entities.add_face(
        [center_x - width/2, center_y - height/2, center_z],
        [center_x + width/2, center_y - height/2, center_z],
        [center_x + width/2, center_y + height/2, center_z],
        [center_x - width/2, center_y + height/2, center_z]
      )
      
      # Create cutouts for the spaces between fingers
      (num_fingers / 2).times do |i|
        # Calculate the position of this cutout
        cutout_center_x = center_x - width/2 + finger_width * (2 * i + 1)
        
        # Create a group for the cutout
        cutout_group = entities.add_group
        
        # Create the cutout shape
        cutout_face = cutout_group.entities.add_face(
          [cutout_center_x - finger_width/2, center_y - height/2, center_z],
          [cutout_center_x + finger_width/2, center_y - height/2, center_z],
          [cutout_center_x + finger_width/2, center_y + height/2, center_z],
          [cutout_center_x - finger_width/2, center_y + height/2, center_z]
        )
        
        # Extrude the cutout
        cutout_face.pushpull(depth)
        
        # Subtract the cutout from the fingers
        fingers_group.entities.subtract(cutout_group.entities)
        
        # Clean up the temporary group
        cutout_group.erase!
      end
      
      # Extrude the fingers
      base_face.pushpull(depth)
      
      # Return the result
      { 
        success: true, 
        id: board.entityID
      }
    end
    
    def create_board2_slots(board, width, height, depth, num_fingers, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      
      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities
      
      # Get the board's bounds
      bounds = board.bounds
      
      # Calculate the position of the joint
      center_x = bounds.center.x + offset_x
      center_y = bounds.center.y + offset_y
      center_z = bounds.center.z + offset_z
      
      # Calculate the width of each finger
      finger_width = width / num_fingers
      
      # Create a group for the slots
      slots_group = entities.add_group
      
      # Create cutouts for the fingers from board 1
      (num_fingers / 2 + num_fingers % 2).times do |i|
        # Calculate the position of this cutout
        cutout_center_x = center_x - width/2 + finger_width * (2 * i)
        
        # Create a group for the cutout
        cutout_group = entities.add_group
        
        # Create the cutout shape
        cutout_face = cutout_group.entities.add_face(
          [cutout_center_x - finger_width/2, center_y - height/2, center_z],
          [cutout_center_x + finger_width/2, center_y - height/2, center_z],
          [cutout_center_x + finger_width/2, center_y + height/2, center_z],
          [cutout_center_x - finger_width/2, center_y + height/2, center_z]
        )
        
        # Extrude the cutout
        cutout_face.pushpull(depth)
        
        # Subtract the cutout from the board
        entities.subtract(cutout_group.entities)
        
        # Clean up the temporary group
        cutout_group.erase!
      end
      
      # Return the result
      { 
        success: true, 
        id: board.entityID
      }
    end
    
    # The binding is created once and reused, so locals set by an earlier call
    # are still there on the next one. The old code duplicated TOPLEVEL_BINDING
    # per call, which forced the caller to resend the whole context every time.
    def eval_ruby(params)
      code = params["code"].to_s
      raise "eval_ruby needs a 'code' string" if code.empty?

      debug "eval_ruby (#{code.length} chars)"
      @eval_binding ||= TOPLEVEL_BINDING.dup

      result = eval(code, @eval_binding, "(mcp eval_ruby)")
      { success: true, result: clamp(result.to_s) }
    rescue SyntaxError, StandardError => e
      log "Error in eval_ruby: #{e.message}"
      debug e.backtrace.join("\n") if e.respond_to?(:backtrace) && e.backtrace
      raise "Ruby evaluation error: #{e.message}"
    end

    # --- MEP quantities -------------------------------------------------
    # Every length reported here comes from a centreline, never from an
    # extruded solid: see su_mcp/bim/route.rb for why.

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
      model  = Sketchup.active_model
      routes = Bim::Route.all(model).reject { |g| Bim::Label.labelled?(g) }
      { success: true, routes: routes.map { |g| { id: g.entityID, metres: Bim::Route.metres(g) } } }
    end

    def mep_schedule
      Bim::Schedule.build(Sketchup.active_model).merge(success: true)
    end

    def mep_build_solids
      { success: true, built: Bim::Solid.rebuild_all(Sketchup.active_model) }
    end

    def mep_export_schedule(params)
      model = Sketchup.active_model
      path  = params["path"].to_s.empty? ? Bim::Export.default_path(model) : params["path"]
      { success: true, path: Bim::Export.csv(Bim::Schedule.build(model), path) }
    end
  end

  ICON_DIR  = File.join(__dir__, "icons").freeze
  PANEL_DIR = File.join(__dir__, "panels").freeze

  # One place that knows what a setting is called and what it falls back to, so
  # a dialog cannot invent a different default than the server already uses.
  module Prefs
    SECTION = "SU_MCP".freeze

    DEFAULTS = {
      "autostart" => false,
      "port"      => Server::DEFAULT_PORT
    }.freeze

    def self.get(key)
      Sketchup.read_default(SECTION, key, DEFAULTS.fetch(key))
    end

    # Refuses a key nothing reads: a typo in a dialog would otherwise write a
    # setting that silently never comes back.
    def self.set(key, value)
      DEFAULTS.fetch(key)
      Sketchup.write_default(SECTION, key, value)
      value
    end

    def self.to_h
      DEFAULTS.keys.each_with_object({}) { |key, h| h[key] = get(key) }
    end
  end

  def self.autostart?
    return true unless ENV['SKETCHUP_MCP_AUTOSTART'].to_s.empty?

    !!Prefs.get("autostart")
  end

  def self.autostart=(enabled)
    Prefs.set("autostart", !!enabled)
  end

  # One toolbar button, one window, one job. They share this plumbing and
  # nothing else: a closed dialog is forgotten, and every action pushes fresh
  # state instead of letting a page keep its own copy of the truth.
  #
  # Decided 2026-09-09: camera, scenes and rendering are NOT this plugin's job.
  # Phanton Studio ships its own SketchUp extension (Studio Live Sync) that owns
  # the viewport, the camera and the round trip to the render service. This one
  # stays the MCP bridge: it drives the model, and measures it.
  DIALOGS = {
    server:   { title: "Máy chủ MCP",   file: "server.html",   width: 320, height: 380 },
    schedule: { title: "Thống kê ống",  file: "schedule.html", width: 430, height: 510 },
    settings: { title: "Cài đặt",       file: "settings.html", width: 360, height: 260 }
  }.freeze

  def self.dialogs
    @dialogs ||= {}
  end

  def self.errors
    @errors ||= {}
  end

  def self.open_dialog(key)
    if (already = dialogs[key])
      already.bring_to_front
      return already
    end

    spec = DIALOGS.fetch(key)
    dialog = UI::HtmlDialog.new(
      dialog_title:    spec[:title],
      preferences_key: "SU_MCP_#{key}",
      resizable:       false,
      width:           spec[:width],
      height:          spec[:height]
    )
    dialog.set_file(File.join(PANEL_DIR, spec[:file]))
    dialog.add_action_callback("ready") { push(key) }
    send("wire_#{key}", dialog)
    dialog.set_on_closed { dialogs.delete(key) }

    # Registered before show: the page calls ready() the moment it loads, and
    # push needs to find the dialog it is answering.
    dialogs[key] = dialog
    dialog.show
    dialog
  end

  def self.push(key)
    dialog = dialogs[key]
    return unless dialog

    dialog.execute_script("render(#{state_for(key).to_json})")
  rescue StandardError => e
    @server.log "Dialog #{key} update failed: #{e.message}"
  end

  # A failed action used to be invisible: the button simply did nothing. Every
  # callback runs in here so the window can say what went wrong.
  def self.guard(key)
    errors[key] = nil
    yield
  rescue StandardError => e
    errors[key] = e.message
    @server.log "#{key}: #{e.message}"
  ensure
    push(key)
  end

  def self.state_for(key)
    base = case key
           when :server   then server_state
           when :schedule then { "schedule" => @schedule, "exported" => @exported }
           when :settings then Prefs.to_h.merge("running" => @server.running?)
           else {}
           end
    base.merge("error" => base["error"] || errors[key])
  end

  def self.server_state
    {
      "running" => @server.running?,
      "host"    => @server.host,
      "port"    => @server.port,
      "error"   => @server.last_error,
      "clients" => @server.client_count,
      "log"     => @server.recent_log(4)
    }
  end

  def self.wire_server(dialog)
    dialog.add_action_callback("start")    { guard(:server) { @server.start } }
    dialog.add_action_callback("stop")     { guard(:server) { @server.stop } }
    dialog.add_action_callback("settings") { open_dialog(:settings) }
  end

  def self.wire_schedule(dialog)
    dialog.add_action_callback("measure") do
      guard(:schedule) { @schedule = Bim::Schedule.build(Sketchup.active_model) }
    end
    dialog.add_action_callback("export") do |_c, path|
      guard(:schedule) do
        model  = Sketchup.active_model
        target = path.to_s.empty? ? Bim::Export.default_path(model) : path
        @schedule = Bim::Schedule.build(model)
        Bim::Export.csv(@schedule, target)
        @exported = target
      end
    end
  end

  def self.wire_settings(dialog)
    dialog.add_action_callback("set") do |_c, key, value|
      guard(:settings) do
        if key.to_s == "port"
          # Refused rather than half-applied: the socket is already bound, and a
          # stored port the server is not listening on is worse than no change.
          @server.port = value
          Prefs.set("port", value.to_i)
        else
          Prefs.set(key.to_s, value)
        end
      end
    end
  end

  unless file_loaded?(__FILE__)
    @server = Server.new
    @server.on_change = -> { SU_MCP.push(:server) }

    menu    = UI.menu("Plugins").add_submenu("MCP Server")
    toolbar = UI::Toolbar.new("MCP Server")

    # One Command object per window, shared by the menu and the toolbar, so a
    # button can never show a different label than its menu item.
    [
      [:server,   "Máy chủ MCP",   "Bật, tắt và theo dõi cầu nối MCP",      "dialog-server"],
      [:schedule, "Thống kê ống",  "Đo tuyến ống MEP và xuất CSV",          "dialog-schedule"],
      [:settings, "Cài đặt",       "Cổng, thư mục ảnh và khổ ảnh mặc định", "dialog-settings"]
    ].each do |key, title, hint, icon|
      command = UI::Command.new(title) { SU_MCP.open_dialog(key) }
      command.set_validation_proc { MF_ENABLED }
      command.tooltip         = title
      command.status_bar_text = hint
      command.large_icon      = File.join(ICON_DIR, "#{icon}-48.png")
      command.small_icon      = File.join(ICON_DIR, "#{icon}-32.png")
      menu.add_item(command)
      toolbar.add_item(command)
    end

    toolbar.restore # remembers whether the user had it showing

    # Deferred: extensions load before SketchUp has finished starting up.
    UI.start_timer(0, false) { @server.start } if SU_MCP.autostart?

    file_loaded(__FILE__)
  end
end
