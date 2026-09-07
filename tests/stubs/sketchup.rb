# Minimal stand-in for the SketchUp Ruby API, enough to exercise su_mcp's
# socket loop, dispatch, undo wrapping and response shaping outside SketchUp.

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
    def initialize(name, &block); @name = name; @block = block; end
    def invoke; @block.call; end
    def set_validation_proc(&block); @validation = block; self; end
    def validate; @validation ? @validation.call : MF_ENABLED; end
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

module Sketchup
  class Face
    def initialize(points); @points = points; end
    def pushpull(_d); true; end
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
    def add_face(*points); Face.new(points); end
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

  class Model
    attr_reader :entities, :selection, :operations
    def initialize
      @entities = Entities.new
      @selection = []
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
    def active_view; self; end
    def write_image(_o); true; end
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
  def self.send_action(_a); end
  def self.require(_f); false; end
end
