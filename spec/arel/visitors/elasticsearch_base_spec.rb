# frozen_string_literal: true

# Covers +Arel::Visitors::ElasticsearchBase+ - the mechanism the whole query builder rests on.
#
# The module is a +ActiveSupport::Concern+ that is mixed into +Arel::Visitors::Elasticsearch+
# (together with the query & schema visitors). To exercise the BASE behaviour in isolation - without
# the ~100 +visit_*+ methods of the real visitor getting in the way - most examples run against a
# minimal host class that includes ONLY this module.
#
# The +SpecVisitNode+ below is that harness: it carries a block which is +instance_exec+'d inside the
# visit, so every example can call the (private) +assign+ / +claim+ / +collect+ / +resolve+ helpers in
# their natural context - during a +compile+, with a real collector attached.
#
# PLEASE NOTE: these specs never touch a cluster - the visitor & collector are plain Ruby.
#
# see @ Arel::Visitors::ElasticsearchBase
# see @ Arel::Collectors::ElasticsearchQuery
RSpec.describe Arel::Visitors::ElasticsearchBase do
  subject(:visitor) { visitor_class.new(connection) }

  let(:connection) { instance_double(ActiveRecord::ConnectionAdapters::ElasticsearchAdapter) }

  # minimal host: a real Arel visitor that includes ONLY the base module
  let(:visitor_class) do
    Class.new(Arel::Visitors::Visitor) do
      include Arel::Visitors::ElasticsearchBase

      # records which dispatch mode reached the visit
      attr_reader :visits

      def initialize(connection)
        super
        @visits = []
      end

      # the harness node - its name demodulizes to itself, so BOTH dispatch modes
      # ('visit_SpecVisitNode' & 'visit_SpecVisitNode') resolve here
      def visit_SpecVisitNode(o)
        instance_exec(&o.block)
      end

      # full dispatch cache -> 'visit_Arel_Nodes_And'
      def visit_Arel_Nodes_And(o)
        @visits << [:full, o]
        :full
      end

      # simple dispatch cache -> 'visit_And'
      def visit_And(o)
        @visits << [:simple, o]
        :simple
      end
    end
  end

  before do
    stub_const('SpecVisitNode', Struct.new(:block))
    stub_const('SpecUnknownNode', Class.new)
  end

  # builds a node that runs the provided block INSIDE the visit
  def node(&block)
    SpecVisitNode.new(block)
  end

  # compiles the provided block and returns the resulting +ElasticsearchRecord::Query+
  def compile(&block)
    visitor.compile(node(&block))
  end

  describe '.simple_dispatch_cache' do
    # the 'simple' cache strips the namespace: +Arel::Nodes::And+ -> 'visit_And'.
    # It is what +SchemaCreation+ switches to, so the schema visitor can define short
    # +visit_TableMappingDefinition+ style methods for its custom nodes.
    # see @ ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaCreation#accept
    it 'maps a class to its demodulized visit method' do
      expect(visitor_class.simple_dispatch_cache[Arel::Nodes::And]).to eq('visit_And')
    end

    it 'keeps a top-level class name untouched' do
      expect(visitor_class.simple_dispatch_cache[SpecVisitNode]).to eq('visit_SpecVisitNode')
    end

    it 'is memoized per class' do
      expect(visitor_class.simple_dispatch_cache).to equal(visitor_class.simple_dispatch_cache)
    end

    it 'caches the resolved method name' do
      cache = visitor_class.simple_dispatch_cache
      cache[Arel::Nodes::And]

      expect(cache.key?(Arel::Nodes::And)).to be(true)
    end

    # PLEASE NOTE: unlike Arel's own +dispatch_cache+ this Hash is NOT +compare_by_identity+ and
    # resolves to a String (Arel resolves to a Symbol) - +send+ accepts both.
    it 'differs from the arel dispatch cache' do
      expect(visitor_class.dispatch_cache[Arel::Nodes::And]).to eq(:visit_Arel_Nodes_And)
    end

    # the ' || "unknown" ' fallback binds to +demodulize+, NOT to +name+ - so an anonymous
    # class never reaches it. Pinned as the current behaviour: nodes must be named classes.
    it 'raises for an anonymous class' do
      expect {
        visitor_class.simple_dispatch_cache[Class.new]
      }.to raise_error(NoMethodError, /undefined method .demodulize. for nil/)
    end
  end

  describe '#initialize' do
    it 'assigns the provided connection' do
      expect(visitor.connection).to equal(connection)
    end

    it 'starts on the full arel dispatch cache' do
      expect(visitor.send(:dispatch)).to equal(visitor_class.dispatch_cache)
    end

    it 'has no collector before the first compile' do
      expect(visitor.collector).to be_nil
    end
  end

  describe '#dispatch_as' do
    it 'switches to the simple dispatch cache inside the block' do
      visitor.dispatch_as(:simple) { visitor.accept(Arel::Nodes::And.new([])) }

      expect(visitor.visits.map(&:first)).to eq([:simple])
    end

    it 'uses the full dispatch cache outside the block' do
      visitor.accept(Arel::Nodes::And.new([]))

      expect(visitor.visits.map(&:first)).to eq([:full])
    end

    # any mode other than +:simple+ falls back to the full cache
    it 'switches to the full dispatch cache for any other mode' do
      visitor.dispatch_as(:simple) do
        visitor.dispatch_as(:full) { visitor.accept(Arel::Nodes::And.new([])) }
      end

      expect(visitor.visits.map(&:first)).to eq([:full])
    end

    it 'restores the previous dispatch cache' do
      visitor.dispatch_as(:simple) { nil }

      expect(visitor.send(:dispatch)).to equal(visitor_class.dispatch_cache)
    end

    it 'restores the previous dispatch cache of a nested call' do
      visitor.dispatch_as(:simple) do
        visitor.dispatch_as(:full) { nil }

        expect(visitor.send(:dispatch)).to equal(visitor_class.simple_dispatch_cache)
      end
    end

    it 'returns the block result' do
      expect(visitor.dispatch_as(:simple) { :result }).to eq(:result)
    end

    # PLEASE NOTE: the restore is NOT wrapped in an ensure - a raising block leaves the visitor on
    # the switched cache. Harmless today because +SchemaCreation+ builds a fresh visit per statement
    # and a raising compile aborts the whole statement anyway.
    it 'does not restore the dispatch cache when the block raises' do
      expect { visitor.dispatch_as(:simple) { raise 'boom' } }.to raise_error('boom')

      expect(visitor.send(:dispatch)).to equal(visitor_class.simple_dispatch_cache)
    end
  end

  describe '#compile' do
    it 'returns the collected query' do
      query = compile { claim(:index, 'my-index') }

      expect(query).to be_a(ElasticsearchRecord::Query)
      expect(query.index).to eq('my-index')
    end

    it 'builds a new collector by default' do
      first  = compile { claim(:index, 'first') }
      second = compile { claim(:index, 'second') }

      expect(first).not_to equal(second)
      expect(first.index).to eq('first')
    end

    it 'compiles into a provided collector' do
      collector = Arel::Collectors::ElasticsearchQuery.new
      collector.claim(:type, ElasticsearchRecord::Query::TYPE_SEARCH)

      query = visitor.compile(node { claim(:index, 'my-index') }, collector)

      expect(query).to equal(collector)
      expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_SEARCH)
    end

    it 'assigns the collector on the visitor' do
      collector = Arel::Collectors::ElasticsearchQuery.new
      visitor.compile(node { nil }, collector)

      expect(visitor.collector).to equal(collector)
    end

    # REGRESSION (fixed in 1.8.2): a raising +assign+ block used to leave +@nested+ = true, so
    # EVERY following compile silently collected its assigns into +@nested_args+ instead of
    # claiming them - resulting in an empty body.
    it 'resets the nested state of a previously raised compile' do
      expect {
        compile { assign(:query, {}) { raise 'boom' } }
      }.to raise_error('boom')

      query = compile { assign(:size, 5) }

      expect(query.body).to eq({ size: 5 })
    end

    it 'resets the nested args of a previously raised compile' do
      expect {
        compile { assign(:query, {}) { assign(:leaked, true); raise 'boom' } }
      }.to raise_error('boom')

      query = compile { assign(:query, {}) { assign(:kept, true) } }

      expect(query.body).to eq({ query: { kept: true } })
    end
  end

  describe '#method_missing' do
    it 'raises for an unhandled visit' do
      expect {
        visitor.send(:visit_Arel_Nodes_Casted, Object.new)
      }.to raise_error(Arel::Visitors::ElasticsearchBase::UnsupportedVisitError,
                       "Unsupported method: 'visit_Arel_Nodes_Casted'. Construct an Arel node instead!")
    end

    # +UnsupportedVisitError+ is NOT a +NoMethodError+ - so it escapes the +rescue+ inside Arel's
    # +#visit+, which would otherwise re-dispatch to a superclass' visit method.
    it 'raises through the arel dispatch instead of resolving a superclass' do
      expect {
        visitor.compile(SpecUnknownNode.new)
      }.to raise_error(Arel::Visitors::ElasticsearchBase::UnsupportedVisitError,
                       /visit_SpecUnknownNode/)
    end

    it 'raises a regular NoMethodError for any other method' do
      expect { visitor.send(:nope) }.to raise_error(NoMethodError, /nope/)
    end

    # PLEASE NOTE: the guard is a plain 'starts with visit' check - not an exact +visit_+ prefix
    it 'raises for any method starting with "visit"' do
      expect {
        visitor.send(:visitors)
      }.to raise_error(Arel::Visitors::ElasticsearchBase::UnsupportedVisitError)
    end
  end

  describe '#collect' do
    it 'returns the visit result of a provided object' do
      result = nil
      compile { result = collect(Arel::Nodes::And.new([])) }

      expect(result).to eq(:full)
    end

    it 'returns an array of results for a provided array' do
      result = nil
      compile { result = collect([Arel::Nodes::And.new([]), Arel::Nodes::And.new([])]) }

      expect(result).to eq([:full, :full])
    end

    it 'returns an empty array for a provided empty array' do
      result = :untouched
      compile { result = collect([]) }

      expect(result).to eq([])
    end

    it 'returns nil for a blank object' do
      results = []
      compile { results = [collect(nil), collect(''), collect(false)] }

      expect(results).to eq([nil, nil, nil])
    end

    it 'sends the provided method instead of :visit' do
      result = nil
      compile { result = collect(Arel::Nodes::And.new([]), :visit_And) }

      expect(result).to eq(:simple)
    end

    it 'does not visit a blank object' do
      compile { collect(nil) }

      expect(visitor.visits).to be_empty
    end
  end

  describe '#resolve' do
    it 'visits a provided object' do
      compile { resolve(Arel::Nodes::And.new([])) }

      expect(visitor.visits.map(&:first)).to eq([:full])
    end

    it 'visits each object of a provided array' do
      compile { resolve([Arel::Nodes::And.new([]), Arel::Nodes::And.new([])]) }

      expect(visitor.visits.length).to eq(2)
    end

    it 'sends the provided method instead of :visit' do
      compile { resolve(Arel::Nodes::And.new([]), :visit_And) }

      expect(visitor.visits.map(&:first)).to eq([:simple])
    end

    it 'skips blank objects' do
      compile { resolve(nil); resolve([]); resolve(false) }

      expect(visitor.visits).to be_empty
    end

    # +resolve+ exists to make 'visit for the side effect' explicit - never rely on its return
    it 'always returns nil' do
      results = []
      compile { results = [resolve(Arel::Nodes::And.new([])), resolve(nil)] }

      expect(results).to eq([nil, nil])
    end
  end

  describe '#claim' do
    it 'sends an [action, args] tuple to the collector' do
      query = compile { claim(:index, 'my-index') }

      expect(query.index).to eq('my-index')
    end

    it 'forwards multiple args' do
      query = compile { claim(:argument, :terminate_after, 5) }

      expect(query.arguments).to eq({ terminate_after: 5 })
    end

    # IMPORTANT: the collector's +claim+ DOES return the assigned value - the visitor's must not,
    # so a 'claim(...)' as the last expression of a +visit_*+ method cannot leak into an assignment.
    it 'always returns nil' do
      result = :untouched
      compile { result = claim(:index, 'my-index') }

      expect(result).to be_nil
    end
  end

  describe '#assign' do
    context 'without a block (TOP-LEVEL)' do
      it 'claims the provided key & value on the query body' do
        query = compile { assign(:size, 5) }

        expect(query.body).to eq({ size: 5 })
      end

      it 'claims each assignment' do
        query = compile { assign(:size, 5); assign(:from, 10) }

        expect(query.body).to eq({ size: 5, from: 10 })
      end

      # +nil+ deletes the key on the collector
      it 'claims a nil value' do
        query = compile { assign(:size, 5); assign(:size, nil) }

        expect(query.body).to eq({})
      end

      it 'returns early for blank args' do
        query = compile { assign(nil); assign(nil, nil) }

        expect(query.body).to eq({})
      end

      it 'raises for a non-Symbol key' do
        expect {
          compile { assign('size', 5) }
        }.to raise_error(ArgumentError, /Unsupported assign key: 'size'/)
      end

      it 'raises for a nil key with a present value' do
        expect {
          compile { assign(nil, 5) }
        }.to raise_error(ArgumentError, /Unsupported assign key/)
      end

      # the special key escapes the body & re-dispatches as a claim - resolved by the COLLECTOR.
      # This is how query-level (non-body) settings are reached from the relation chain.
      # see @ ElasticsearchRecord::Relation::QueryMethods#configure
      it 'claims the special :__query__ key' do
        query = compile { assign(:__query__, { refresh: true }) }

        expect(query.refresh).to be(true)
        expect(query.body).to eq({})
      end
    end

    context 'with a block (NESTED)' do
      it 'merges the nested assignments into the parent value' do
        query = compile do
          assign(:query, {}) do
            assign(:bool, {}) do
              assign(:x, 99)
              assign({ y: 45 })
            end
          end
        end

        expect(query.body).to eq({ query: { bool: { x: 99, y: 45 } } })
      end

      it 'does not claim the nested assignments' do
        query = compile { assign(:query, {}) { assign(:bool, {}) } }

        expect(query.body).to eq({ query: { bool: {} } })
      end

      it 'raises for a nil parent value' do
        expect {
          compile { assign(:query, nil) { assign(:bool, {}) } }
        }.to raise_error(ArgumentError, /Unsupported assignment value for provided block \(query\)/)
      end

      it 'claims an empty parent value for an empty block' do
        query = compile { assign(:query, {}) { nil } }

        expect(query.body).to eq({ query: {} })
      end

      it 'restores the nested state after the block' do
        query = compile do
          assign(:query, {}) { assign(:bool, {}) }
          assign(:size, 5)
        end

        expect(query.body).to eq({ query: { bool: {} }, size: 5 })
      end

      # the nested path is checked BEFORE the Symbol guard, so nested keys are unrestricted
      it 'does not restrict a nested key to a Symbol' do
        query = compile { assign(:query, {}) { assign('term', 1) } }

        expect(query.body).to eq({ query: { 'term' => 1 } })
      end

      context 'with a Hash parent' do
        it 'merges a nested Hash without a key' do
          query = compile { assign(:query, { a: 1 }) { assign({ b: 2 }) } }

          expect(query.body).to eq({ query: { a: 1, b: 2 } })
        end

        # the 'nil key delegates to the value' special case
        it 'merges a nested Hash value assigned on a nil key' do
          query = compile { assign(:query, { a: 1 }) { assign(nil, { b: 2 }) } }

          expect(query.body).to eq({ query: { a: 1, b: 2 } })
        end

        it 'deep merges into an existing Hash key' do
          query = compile { assign(:query, { bool: { must: [] } }) { assign(:bool, { filter: [] }) } }

          expect(query.body).to eq({ query: { bool: { must: [], filter: [] } } })
        end

        it 'appends into an existing Array key' do
          query = compile { assign(:bool, { filter: [{ a: 1 }] }) { assign(:filter, [{ b: 2 }]) } }

          expect(query.body).to eq({ bool: { filter: [{ a: 1 }, { b: 2 }] } })
        end

        it 'deletes a key for a nested nil value' do
          query = compile { assign(:query, { a: 1, b: 2 }) { assign(:b, nil) } }

          expect(query.body).to eq({ query: { a: 1 } })
        end

        # +:__force__+ is the escape hatch to assign an explicit nil (e.g. a 'null' mapping value)
        it 'keeps a nested nil value assigned with :__force__' do
          query = compile { assign(:query, { a: 1 }) { assign(:b, nil, :__force__) } }

          expect(query.body).to eq({ query: { a: 1, b: nil } })
        end

        it 'overwrites a scalar key' do
          query = compile { assign(:query, { a: 1 }) { assign(:a, 2) } }

          expect(query.body).to eq({ query: { a: 2 } })
        end

        it 'overwrites a Hash key with a non-Hash value' do
          query = compile { assign(:query, { a: { b: 1 } }) { assign(:a, 2) } }

          expect(query.body).to eq({ query: { a: 2 } })
        end

        it 'applies the nested assignments in order' do
          query = compile { assign(:query, {}) { assign(:a, 1); assign(:a, 2) } }

          expect(query.body).to eq({ query: { a: 2 } })
        end
      end

      context 'with an Array parent' do
        it 'appends a nested key' do
          query = compile { assign(:filter, []) { assign({ term: { a: 1 } }) } }

          expect(query.body).to eq({ filter: [{ term: { a: 1 } }] })
        end

        it 'concats each entry of a nested Array' do
          query = compile { assign(:filter, [{ a: 1 }]) { assign([{ b: 2 }, { c: 3 }]) } }

          expect(query.body).to eq({ filter: [{ a: 1 }, { b: 2 }, { c: 3 }] })
        end

        # the 'nil key delegates to the value' special case
        it 'appends a value assigned on a nil key' do
          query = compile { assign(:filter, []) { assign(nil, { term: { a: 1 } }) } }

          expect(query.body).to eq({ filter: [{ term: { a: 1 } }] })
        end

        it 'appends each nested assignment' do
          query = compile { assign(:filter, []) { assign({ a: 1 }); assign({ b: 2 }) } }

          expect(query.body).to eq({ filter: [{ a: 1 }, { b: 2 }] })
        end
      end

      context 'with a String parent' do
        it 'concats a nested key' do
          query = compile { assign(:script, 'ctx.') { assign('_source.a = 1') } }

          expect(query.body).to eq({ script: 'ctx._source.a = 1' })
        end

        it 'concats each entry of a nested Array' do
          query = compile { assign(:script, 'ctx.') { assign(['a', 'b']) } }

          expect(query.body).to eq({ script: 'ctx.ab' })
        end

        # the 'nil key delegates to the value' special case
        it 'concats a value assigned on a nil key' do
          query = compile { assign(:script, 'ctx.') { assign(nil, 'a') } }

          expect(query.body).to eq({ script: 'ctx.a' })
        end

        it 'concats an Array assigned on a nil key' do
          query = compile { assign(:script, 'ctx.') { assign(nil, ['a', 'b']) } }

          expect(query.body).to eq({ script: 'ctx.ab' })
        end

        it 'casts a nested non-String key' do
          query = compile { assign(:script, 'v') { assign(1) } }

          expect(query.body).to eq({ script: 'v1' })
        end
      end

      # anything that is not a Hash / Array / String: the LAST nested key REPLACES the parent value
      context 'with a scalar parent' do
        it 'replaces the parent value with the nested key' do
          query = compile { assign(:size, 5) { assign(10) } }

          expect(query.body).to eq({ size: 10 })
        end

        it 'keeps the parent value for a blank nested assignment' do
          query = compile { assign(:size, 5) { assign(nil) } }

          expect(query.body).to eq({ size: 5 })
        end
      end

      context 'with more than one level' do
        it 'restores the nested args of the parent level' do
          query = compile do
            assign(:query, {}) do
              assign(:a, 1)
              assign(:bool, {}) { assign(:b, 2) }
              assign(:c, 3)
            end
          end

          expect(query.body).to eq({ query: { a: 1, bool: { b: 2 }, c: 3 } })
        end

        it 'merges three levels' do
          query = compile do
            assign(:aggs, {}) do
              assign(:by_name, {}) do
                assign(:terms, {}) { assign(:field, 'name') }
              end
            end
          end

          expect(query.body).to eq({ aggs: { by_name: { terms: { field: 'name' } } } })
        end

        it 'claims a sibling top-level assignment after the nested block' do
          query = compile do
            assign(:query, {}) { assign(:bool, {}) { assign(:a, 1) } }
            assign(:size, 5)
          end

          expect(query.body).to eq({ query: { bool: { a: 1 } }, size: 5 })
        end
      end

      # +:__query__+ never reaches the body - it is claimed by the collector. Nested inside a block
      # it is collected as a regular nested arg, so it only escapes on the TOP-LEVEL assignment.
      it 'does not claim a nested :__query__ key as a query setting' do
        query = compile { assign(:query, {}) { assign(:__query__, { refresh: true }) } }

        expect(query.refresh).to be_nil
        expect(query.body).to eq({ query: { __query__: { refresh: true } } })
      end
    end
  end

  describe '#failed!' do
    it 'claims a failed status' do
      query = compile { failed! }

      expect(query.status).to eq(ElasticsearchRecord::Query::STATUS_FAILED)
    end

    # a failed query is NOT an error - it swaps in a body that matches nothing (SQL 'where 1=0')
    it 'swaps in the failed body' do
      query = compile do
        claim(:type, ElasticsearchRecord::Query::TYPE_SEARCH)
        assign(:size, 5)
        failed!
      end

      expect(query.body).to eq(ElasticsearchRecord::Query::FAILED_BODIES[ElasticsearchRecord::Query::TYPE_SEARCH])
    end

    it 'returns nil' do
      result = :untouched
      compile { result = failed! }

      expect(result).to be_nil
    end
  end

  describe 'HELPERS' do
    describe '#unboundable?' do
      it 'is true for an unboundable value' do
        expect(visitor.send(:unboundable?, double(unboundable?: true))).to be(true)
      end

      it 'is false for a bounded value' do
        expect(visitor.send(:unboundable?, double(unboundable?: false))).to be(false)
      end

      it 'is false for a value that does not respond to it' do
        expect(visitor.send(:unboundable?, 5)).to be(false)
      end
    end

    describe '#invalid?' do
      # ActiveRecord builds a literal '1=0' for a relation that can never match
      it 'is true for the "1=0" literal' do
        expect(visitor.send(:invalid?, '1=0')).to be(true)
      end

      it 'is true for a SqlLiteral "1=0"' do
        expect(visitor.send(:invalid?, Arel::Nodes::SqlLiteral.new('1=0'))).to be(true)
      end

      it 'is false for any other value' do
        expect(visitor.send(:invalid?, '1=1')).to be(false)
      end
    end

    describe '#quote' do
      it 'quotes the value through the connection' do
        expect(connection).to receive(:quote).with('name').and_return("'name'")

        expect(visitor.send(:quote, 'name')).to eq("'name'")
      end

      it 'returns a SqlLiteral untouched' do
        expect(connection).not_to receive(:quote)

        literal = Arel::Nodes::SqlLiteral.new('name')

        expect(visitor.send(:quote, literal)).to equal(literal)
      end
    end
  end

  # the real visitor mixes this module in - these pin that the wiring is actually in place
  describe 'Arel::Visitors::Elasticsearch' do
    subject(:visitor) { Arel::Visitors::Elasticsearch.new(connection) }

    it 'includes the base module' do
      expect(Arel::Visitors::Elasticsearch.include?(described_class)).to be(true)
    end

    it 'assigns the connection' do
      expect(visitor.connection).to equal(connection)
    end

    it 'raises for an unsupported node' do
      expect {
        visitor.compile(SpecUnknownNode.new)
      }.to raise_error(described_class::UnsupportedVisitError, /visit_SpecUnknownNode/)
    end

    it 'compiles into an ElasticsearchRecord::Query' do
      query = visitor.compile(Arel::SelectManager.new(Arel::Table.new('my-index')).ast)

      expect(query).to be_a(ElasticsearchRecord::Query)
      expect(query.index).to eq('my-index')
    end
  end
end
