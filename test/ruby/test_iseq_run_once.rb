# frozen_string_literal: false
require 'test/unit'
require 'tmpdir'

# Prototype: RUBY_ISEQ_RELEASE_RUN_ONCE=1 releases the instructions of
# top-level ISeqs of loaded files (and the class bodies they define) after
# they have run.
class TestISeqRunOnce < Test::Unit::TestCase
  LIB = <<~'RUBY'
    LOCS = []
    module RunOnceA
      X = 1
      LOCS << caller_locations(0, 1).first
      class Inner
        y = 42
        LOCS << caller_locations(0, 1).first
        begin
          raise "boom"
        rescue => e
          ERR = e
        end
        KEEP = proc { |a| [y, a, binding.local_variables.sort, eval("y + 1")] }
        BIND = binding
        def hello(n) = "hello #{n} #{X}"
        class << self
          def sing = :sing
        end
      end
    end
  RUBY

  def run_lib(code)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "lib_a.rb"), LIB)
      assert_separately([{"RUBY_ISEQ_RELEASE_RUN_ONCE" => "1"}, "-I", dir], <<~PRE + code)
        $top = nil
        TracePoint.new(:script_compiled) { |t| $top ||= t.instruction_sequence if t.instruction_sequence&.path&.end_with?("lib_a.rb") }.enable { require "lib_a" }
        3.times { GC.start }
      PRE
    end
  end

  def test_released_and_children_collected
    run_lib(<<~'RUBY')
      st = RubyVM::InstructionSequence.run_once_release_stats
      assert_operator st[:released], :>=, 3
      kids = []
      $top.each_child { |c| kids << c }
      assert_empty kids
      assert_equal [], $top.trace_points
      assert_kind_of String, $top.disasm
      assert_kind_of Array, $top.to_a
      assert_raise(TypeError) { $top.eval }
      assert_raise(RuntimeError) { $top.to_binary }
      GC.verify_internal_consistency
    RUBY
  end

  def test_line_info_and_bindings_survive
    run_lib(<<~'RUBY')
      assert_equal [4, 7], LOCS.map(&:lineno)
      assert_equal 9, RunOnceA::Inner::ERR.backtrace_locations[0].lineno
      assert_equal [42, 5, [:a, :e, :y], 43], RunOnceA::Inner::KEEP.call(5)
      assert_equal 84, RunOnceA::Inner::BIND.eval("y * 2")
      assert_equal "hello 1 1", RunOnceA::Inner.new.hello(1)
      assert_equal :sing, RunOnceA::Inner.sing
      events = []
      TracePoint.new(:line, :b_call) { |t| events << t.event }.enable { RunOnceA::Inner::KEEP.call(1) }
      assert_include events, :b_call
      GC.verify_compaction_references(expand_heap: true, toward: :empty)
      assert_equal 7, LOCS[1].lineno
      assert_equal 7, RunOnceA::Inner::KEEP.call(7)[1]
    RUBY
  end
end
