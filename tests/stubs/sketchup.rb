# Minimal stand-in for the SketchUp Ruby API, enough to exercise su_mcp's
# socket loop, dispatch, undo wrapping and response shaping outside SketchUp.

require 'json'
require 'fileutils'

# SketchUp defines these on Kernel for its extension loading dance.
module Kernel
  def file_loaded?(_file); false; end
  def file_loaded(_file); true; end
end

SKETCHUP_CONSOLE = Object.new
def SKETCHUP_CONSOLE.show; end
def SKETCHUP_CONSOLE.write(msg); $stderr.print(msg) if ENV['STUB_VERBOSE']; end

MF_ENABLED   = 0
MF_DISABLED  = 1
MF_CHECKED   = 2
MF_UNCHECKED = 3
MF_GRAYED    = 4

module UI
  @timers = {}
  @menu = nil
  class << self
    attr_reader :timers
    def start_timer(_interval, repeat = false, &block)
      id = @timers.size + 1
      @timers[id] = { block: block, repeat: repeat }
      id
    end
    def stop_timer(id); @timers.delete(id); end
    def tick!
      @timers.to_a.each do |id, timer|
        @timers.delete(id) unless timer[:repeat]
        timer[:block].call
      end
    end
    def menu(_name); @menu ||= FakeMenu.new; end
    def messagebox(_msg); end
  end

  class Command
    attr_reader :name
    attr_accessor :tooltip, :status_bar_text, :large_icon, :small_icon
    def initialize(name, &block); @name = name; @block = block; end
    def invoke; @block.call; end
    def set_validation_proc(&block); @validation = block; self; end
    def validate; @validation ? @validation.call : MF_ENABLED; end
  end

  class Toolbar
    @all = {}
    class << self
      def all; @all; end
      def [](name); @all[name]; end
    end
    attr_reader :name, :items
    def initialize(name)
      @name = name
      @items = []
      self.class.all[name] = self
    end
    def add_item(command); @items << command; self; end
    def restore; @restored = true; self; end
    def restored?; !!@restored; end
    def [](name); @items.find { |c| c.name == name }; end
  end

  # Records what Ruby pushed into the panel instead of running a browser.
  class HtmlDialog
    STYLE_DIALOG  = 0
    STYLE_WINDOW  = 1
    STYLE_UTILITY = 2

    @last = nil
    class << self; attr_accessor :last; end

    attr_reader :options, :file, :scripts, :callbacks
    def initialize(options = {})
      @options = options
      @callbacks = {}
      @scripts = []
      @visible = false
      self.class.last = self
    end
    def set_file(path); @file = path; end
    def add_action_callback(name, &block); @callbacks[name] = block; end
    def set_on_closed(&block); @on_closed = block; end
    def execute_script(js); @scripts << js; end
    # The real page calls sketchup.ready() as soon as it loads.
    def show
      @visible = true
      @callbacks["ready"]&.call(nil)
    end
    def visible?; @visible; end
    def bring_to_front; @fronted = true; end
    def fronted?; !!@fronted; end
    def close; @visible = false; @on_closed&.call; end
    # Stands in for a click in the panel.
    def invoke(name, *args); @callbacks.fetch(name).call(nil, *args); end
    def last_state
      js = @scripts.reverse.find { |s| s.start_with?("render(") }
      js && JSON.parse(js[/\Arender\((.*)\)\z/m, 1])
    end
  end

  class FakeMenu
    attr_reader :items
    def initialize; @items = []; end
    def add_submenu(_n); self; end
    def add_item(item, &block)
      command = item.is_a?(Command) ? item : Command.new(item, &block)
      @items << command
      command
    end
    def [](name); @items.find { |c| c.name == name }; end
  end
end

module Geom
  class Point3d
    attr_accessor :x, :y, :z
    def initialize(x = 0, y = 0, z = 0); @x = x.to_f; @y = y.to_f; @z = z.to_f; end
    def to_a; [@x, @y, @z]; end
    def distance(other)
      Math.sqrt((@x - other.x)**2 + (@y - other.y)**2 + (@z - other.z)**2)
    end
  end

  class Vector3d
    attr_reader :x, :y, :z
    def initialize(x, y, z); @x = x.to_f; @y = y.to_f; @z = z.to_f; end
    def dot(o); @x * o.x + @y * o.y + @z * o.z; end
  end
end

module Sketchup
  # Edge#start / #end return a Vertex in the real API, not a point — the point
  # is behind Vertex#position. Getting this wrong here hid a real crash.
  class Vertex
    attr_reader :position
    def initialize(point); @position = point; end
  end

  class Edge
    attr_reader :start, :end
    def initialize(a, b); @start = Vertex.new(a); @end = Vertex.new(b); end
    def length; @start.position.distance(@end.position); end
    def typename; "Edge"; end
  end

  # Attributes and classification live on the definition, not the instance —
  # the same as the real API.
  class Definition
    def initialize(instance); @instance = instance; @dicts = {}; @classification = {}; end
    def set_attribute(dict, key, value); (@dicts[dict] ||= {})[key] = value; true; end
    def get_attribute(dict, key, fallback = nil); (@dicts[dict] || {}).fetch(key, fallback); end
    def attribute_dictionary(name, _create = false); @dicts[name]; end
    def set_classification_value(path, value); @classification[path.join("/")] = value; true; end
    # Mirrors the measured behaviour on SketchUp Pro 24.0.483: the schemas are
    # listed but nothing attaches. A stub that returned true here hid that.
    def add_classification(_schema, _type); false; end
    def get_classification_value(path); @classification[path.join("/")]; end
    def name; @instance.name; end
  end

  class Face
    attr_reader :pulled
    def initialize(points, normal = nil); @points = points; @normal = normal; end
    def normal; @normal || Geom::Vector3d.new(0, 0, 1); end
    def pushpull(d); @pulled = d; true; end
  end

  class Entities
    include Enumerable
    def initialize; @items = []; end
    def each(&b); @items.each(&b); end
    def length; @items.length; end
    def add_group
      g = Group.new
      @items << g
      g
    end
    def add_circle(center, normal, radius, _segments = 12)
      @last_normal = normal
      edge = Edge.new(center, Geom::Point3d.new(center.x + radius, center.y, center.z))
      @items << edge
      [edge]
    end
    def add_face(*points)
      Face.new(points, @last_normal)
    end
    def add_edges(*points)
      pts = points.flatten
      edges = []
      pts.each_cons(2) { |a, b| edges << Edge.new(a, b) }
      edges.each { |e| @items << e }
      edges
    end
    def select(&b); @items.select(&b); end
    def first(n); @items.first(n); end
  end

  class Group
    @@next_id = 100
    attr_reader :entities
    attr_accessor :name
    def initialize
      @@next_id += 1
      @id = @@next_id
      @entities = Entities.new
      @name = ""
    end
    def entityID; @id; end
    def definition; @definition ||= Definition.new(self); end
    def erase!; true; end
    def typename; "Group"; end
    def bounds; BoundingBox.new; end
  end

  class ComponentInstance < Group
    def typename; "ComponentInstance"; end
  end

  class Point
    def initialize(a); @a = a; end
    def to_a; @a; end
  end

  class BoundingBox
    def min; Point.new([0.0, 0.0, 0.0]); end
    def max; Point.new([10.0, 10.0, 10.0]); end
  end

  class View
    attr_reader :written
    def initialize; @written = []; end
    def write_image(options)
      path = options[:filename] || options["filename"]
      return false if path.to_s.empty?

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "png")
      @written << options
      true
    end
  end

  # A plain Array stood in for this, which answers #clear but not #add — so a
  # panel highlighting the route it is editing blew up only outside the tests.
  class Selection
    include Enumerable
    def initialize; @items = []; end
    def each(&b); @items.each(&b); end
    def length; @items.length; end
    def empty?; @items.empty?; end
    def clear; @items.clear; self; end
    def add(entity); @items.concat(Array(entity)); self; end
    def include?(entity); @items.include?(entity); end
    # Not a SketchUp method — the tests use it to set a selection up.
    def replace(items); @items.replace(Array(items)); self; end
    def to_a; @items.dup; end
    def first; @items.first; end
  end

  class Model
    attr_reader :entities, :selection, :operations
    def initialize
      @entities = Entities.new
      @selection = Selection.new
      @operations = []
    end
    def active_entities; @entities; end
    def title; "StubModel"; end
    def path; "/tmp/stub.skp"; end
    def bounds; BoundingBox.new; end
    def layers; [OpenStructish.new("Layer0")]; end
    def materials; [OpenStructish.new("Wood")]; end
    def options; { "UnitsOptions" => { "LengthUnit" => 0 } }; end
    def start_operation(name, _ui = false); @operations << [:start, name]; true; end
    def commit_operation; @operations << [:commit]; true; end
    def abort_operation; @operations << [:abort]; true; end
    def find_entity_by_id(id); @entities.find { |e| e.entityID == id }; end
    def save(path); File.write(path, "skp"); true; end
    def export(_path, _opts); false; end
    def active_view; @view ||= View.new; end
    def set_attribute(dict, key, value); ((@dicts ||= {})[dict] ||= {})[key] = value; true; end
    def get_attribute(dict, key, fallback = nil); ((@dicts ||= {})[dict] || {}).fetch(key, fallback); end
  end

  class OpenStructish
    attr_reader :name
    def initialize(name); @name = name; end
  end

  @model = Model.new
  @defaults = {}
  def self.active_model; @model; end
  def self.read_default(section, key, fallback = nil)
    @defaults.fetch("#{section}/#{key}", fallback)
  end
  def self.write_default(section, key, value)
    @defaults["#{section}/#{key}"] = value
    true
  end
  def self.send_action(_action); end
  def self.require(_f); false; end
end
