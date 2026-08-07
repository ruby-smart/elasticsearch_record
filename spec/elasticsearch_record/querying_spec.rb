# frozen_string_literal: true

# Covers every public method of +ElasticsearchRecord::Querying::ClassMethods+.
#
# These are the class-level entry points into the query pipeline. They either build an
# +ElasticsearchRecord::Query+ and instantiate records from the response (+find_by_*+) or
# execute a RAW query and return the +ElasticsearchRecord::Result+ as-is (+esql+, +msearch+).
#
# see @ ElasticsearchRecord::Querying::ClassMethods
RSpec.describe ElasticsearchRecord::Querying::ClassMethods, :elasticsearch do
  # PLEASE NOTE: the +:elasticsearch+ tag skips these examples through a +before(:each)+ hook
  # (see spec_helper.rb) - so the index setup must NOT run in a +before(:all)+, which would
  # execute before that hook and blow up instead of skipping.
  before do
    TestIndex.create!

    model.create!(name: 'alpha', count: 1, active: true)
    model.create!(name: 'beta', count: 2, active: false)
    model.create!(name: 'gamma', count: 3, active: true)
    model.api.refresh!
  end

  after { TestIndex.drop! }

  subject(:model) do
    Class.new(ElasticsearchRecord::Base) {
      def self.name = 'QueryingSpecModel'
    }.tap { |klass|
      klass.table_name = TestIndex.name
      klass.reset_column_information
    }
  end

  # captures the +ElasticsearchRecord::Query+ that is handed to the connection - the query
  # object IS the "SQL" of this adapter, so this is the only way to assert what was built.
  def capture_query(method = :select_all)
    captured = nil

    allow(model.connection).to receive(method).and_wrap_original do |original, query, *args, **opts|
      captured = query
      original.call(query, *args, **opts)
    end

    yield

    captured
  end

  # +search+ branches on the +elasticsearch-dsl+ gem being loadable. The gem is NOT a
  # dependency of this project, so both branches are guarded instead of assumed.
  def dsl_available?
    require 'elasticsearch/dsl'
    true
  rescue LoadError
    false
  end

  describe 'ES_QUERYING_METHODS' do
    it 'lists the additionally delegated relation methods' do
      expect(described_class::ES_QUERYING_METHODS).to eq(%i[query filter must must_not should aggregate msearch])
    end

    it 'is frozen' do
      expect(described_class::ES_QUERYING_METHODS).to be_frozen
    end

    # +msearch+ is excluded here - see the example below
    %i[query filter must must_not should aggregate].each do |method|
      it "delegates ##{method} to the current relation" do
        relation = model.all
        allow(model).to receive(:all).and_return(relation)

        expect(relation).to receive(method).with(:some, :args).and_return(:delegated)
        expect(model.public_send(method, :some, :args)).to eq(:delegated)
      end
    end

    it 'spawns a relation through a delegated method' do
      relation = model.filter(term: { name: 'alpha' })

      expect(relation).to be_a(ActiveRecord::Relation)
      expect(relation.map(&:name)).to eq(['alpha'])
    end

    # PLEASE NOTE: +msearch+ is part of +ES_QUERYING_METHODS+, but the class-level +#msearch+
    # is defined AFTER the +delegate+ call within the same module - so it SHADOWS the delegation.
    # +Model.msearch+ therefore expects RAW queries and does NOT reach
    # +ElasticsearchRecord::Relation::CoreMethods#msearch+ (use +Model.all.msearch+ for that).
    it 'does not delegate #msearch to the relation' do
      expect(model.method(:msearch).parameters).to eq([[:req, :queries]])
    end
  end

  describe '.find_by_id' do
    # the default test index has no 'id' mapping - the primary key is the metadata field '_id'
    context 'without a mapped id attribute' do
      it 'resolves the record by its _id' do
        record = model.first

        expect(model.find_by_id(record._id)).to eq(record)
      end

      it 'resolves through #find_by__id' do
        expect(model).to receive(:find_by__id).with('some-id')

        model.find_by_id('some-id')
      end

      it 'returns nil for an unknown id' do
        expect(model.find_by_id('nope')).to be_nil
      end
    end

    context 'with a mapped id attribute' do
      let(:index_name) { "#{TestIndex.name}_ids" }

      let(:id_model) do
        Class.new(ElasticsearchRecord::Base) {
          def self.name = 'QueryingIdSpecModel'

          self.delegate_id_attribute = true
        }.tap { |klass|
          klass.table_name = index_name
          klass.reset_column_information
        }
      end

      before do
        TestIndex.create!(index_name) do |t|
          t.mapping :id, :keyword
          t.mapping :name, :keyword
        end

        id_model.create!(id: 'custom-1', name: 'alpha')
        id_model.api.refresh!
      end

      after { TestIndex.drop!(index_name) }

      it 'resolves the record by the mapped id field' do
        expect(id_model.find_by_id('custom-1').name).to eq('alpha')
      end

      it 'does not resolve through #find_by__id' do
        expect(id_model).not_to receive(:find_by__id)

        id_model.find_by_id('custom-1')
      end

      it 'does not resolve the record by its _id' do
        expect(id_model.find_by_id(id_model.first._id)).to be_nil
      end

      it 'returns nil for an unknown id' do
        expect(id_model.find_by_id('nope')).to be_nil
      end
    end
  end

  describe '.find_by_sql' do
    context 'with a provided Hash' do
      it 'instantiates records from the provided query arguments' do
        records = model.find_by_sql({ index: TestIndex.name, body: { query: { match_all: {} } } })

        expect(records).to all(be_a(model))
        expect(records.map(&:name)).to match_array(%w[alpha beta gamma])
      end

      it 'builds a search query from the provided arguments' do
        arguments = { index: TestIndex.name, body: { query: { term: { name: 'alpha' } } } }

        query = capture_query { model.find_by_sql(arguments) }

        expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_SEARCH)
        expect(query.arguments).to eq(arguments)
      end

      it 'always provides all source columns' do
        query = capture_query { model.find_by_sql({ index: TestIndex.name, body: { query: { match_all: {} } } }) }

        expect(query.columns).to eq(model.source_column_names)
      end

      it 'returns an empty array for a non-matching query' do
        expect(model.find_by_sql({ index: TestIndex.name, body: { query: { term: { name: 'nope' } } } })).to eq([])
      end

      it 'raises for an invalid query' do
        expect {
          model.find_by_sql({ index: TestIndex.name, body: { query: { nope: {} } } })
        }.to raise_error(ActiveRecord::StatementInvalid)
      end
    end

    context 'with a provided Query' do
      let(:query) do
        ElasticsearchRecord::Query.new(
          index:   TestIndex.name,
          type:    ElasticsearchRecord::Query::TYPE_SEARCH,
          body:    { query: { term: { name: 'alpha' } } },
          columns: model.source_column_names)
      end

      it 'instantiates records from the provided query' do
        expect(model.find_by_sql(query).map(&:name)).to eq(['alpha'])
      end

      it 'executes the provided query as-is' do
        expect(capture_query { model.find_by_sql(query) }).to equal(query)
      end
    end

    context 'with a provided String' do
      # PLEASE NOTE: this documents the INTENDED behaviour - the current implementation
      # references an undefined local variable +query_or_sql+ (instead of the +sql+ parameter)
      # and raises a NameError for any provided String.
      # see @ ElasticsearchRecord::Querying::ClassMethods#find_by_sql
      it 'instantiates records from a SQL string' do
        expect(model.find_by_sql("SELECT name FROM #{TestIndex.name}").map(&:name)).to match_array(%w[alpha beta gamma])
      end
    end

    it 'yields each instantiated record' do
      yielded = []

      model.find_by_sql({ index: TestIndex.name, body: { query: { match_all: {} } } }) { |record| yielded << record }

      expect(yielded).to all(be_a(model))
      expect(yielded.map(&:name)).to match_array(%w[alpha beta gamma])
    end

    # +binds+ & +preparable+ only exist to satisfy +ActiveRecord::StatementCache#execute+ -
    # this adapter has no bind params.
    it 'ignores provided binds & the preparable flag' do
      records = model.find_by_sql(
        { index: TestIndex.name, body: { query: { match_all: {} } } },
        [1, 2],
        preparable: true)

      expect(records.map(&:name)).to match_array(%w[alpha beta gamma])
    end
  end

  describe '.find_by_query' do
    it 'instantiates records from the provided query arguments' do
      records = model.find_by_query({ body: { query: { match_all: {} } } })

      expect(records).to all(be_a(model))
      expect(records.map(&:name)).to match_array(%w[alpha beta gamma])
    end

    it 'builds a search query against the table_name' do
      query = capture_query { model.find_by_query({ body: { query: { match_all: {} } } }) }

      expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_SEARCH)
      expect(query.index).to eq(model.table_name)
      expect(query.arguments).to eq({ body: { query: { match_all: {} } } })
    end

    it 'always provides all source columns' do
      query = capture_query { model.find_by_query({ body: { query: { match_all: {} } } }) }

      expect(query.columns).to eq(model.source_column_names)
    end

    # without the provided columns a doc that has no value for a mapped field would end up
    # with a MISSING attribute instead of a nil one
    it 'resolves all mapped attributes - even for a partially stored doc' do
      model.create!(name: 'delta')
      model.api.refresh!

      record = model.find_by_query({ body: { query: { term: { name: 'delta' } } } }).first

      expect(record.attributes.keys).to include('name', 'count', 'active', 'created_at')
      expect(record.count).to be_nil
    end

    it 'respects the provided query arguments' do
      expect(model.find_by_query({ body: { query: { term: { active: true } } } }).map(&:name))
        .to match_array(%w[alpha gamma])
    end

    it 'yields each instantiated record' do
      yielded = []

      model.find_by_query({ body: { query: { match_all: {} } } }) { |record| yielded << record }

      expect(yielded.map(&:name)).to match_array(%w[alpha beta gamma])
    end

    it 'returns an empty array for a non-matching query' do
      expect(model.find_by_query({ body: { query: { term: { name: 'nope' } } } })).to eq([])
    end

    it 'raises for an invalid query' do
      expect {
        model.find_by_query({ body: { query: { nope: {} } } })
      }.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  describe '.find_by_esql' do
    it 'builds an ES|QL query from the provided string' do
      query = capture_query { model.find_by_esql("FROM #{TestIndex.name} | LIMIT 10") }

      expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_ESQL)
      expect(query.body).to eq({ query: "FROM #{TestIndex.name} | LIMIT 10" })
    end

    it 'resolves the ES|QL gate' do
      query = capture_query { model.find_by_esql("FROM #{TestIndex.name} | LIMIT 10") }

      expect(query.gate).to eq('esql.query')
    end

    it 'always provides all source columns' do
      query = capture_query { model.find_by_esql("FROM #{TestIndex.name} | LIMIT 10") }

      expect(query.columns).to eq(model.source_column_names)
    end

    it 'raises for an invalid ES|QL query' do
      expect { model.find_by_esql('FROM | nope') }.to raise_error(ActiveRecord::StatementInvalid)
    end

    # PLEASE NOTE: this documents the INTENDED behaviour. An ES|QL response has no 'hits' node -
    # it returns 'columns' & 'values' - which +ElasticsearchRecord::Result+ does not resolve,
    # so +computed_results+ is always empty and NO record is ever instantiated.
    # see @ ElasticsearchRecord::Result#computed_results
    it 'instantiates records from the ES|QL response' do
      records = model.find_by_esql("FROM #{TestIndex.name} | LIMIT 10")

      expect(records).to all(be_a(model))
      expect(records.map(&:name)).to match_array(%w[alpha beta gamma])
    end
  end

  describe '.esql' do
    # the built query is only reachable through a stubbed connection - +esql+ returns the RESULT,
    # not the query it sent
    let(:connection_stub) { instance_double(ActiveRecord::ConnectionAdapters::ElasticsearchAdapter) }

    # +#esql+ asserts the cluster is new enough to know the 'esql' namespace at all
    # see @ ElasticsearchRecord::Querying::ClassMethods#_esql_query
    before do
      allow(connection_stub).to receive(:cluster_info).and_return({ version: Gem::Version.new('8.19.0') })
    end

    def capture_esql_query
      # resolve the columns BEFORE the connection gets stubbed
      model.source_column_names

      captured = nil
      allow(model).to receive(:connection).and_return(connection_stub)
      allow(connection_stub).to receive(:exec_query) do |query, *_args, **_opts|
        captured = query
        ElasticsearchRecord::Result.empty
      end

      yield

      captured
    end

    it 'raises for a cluster that does not know ES|QL yet' do
      allow(model).to receive(:connection).and_return(connection_stub)
      allow(connection_stub).to receive(:cluster_info).and_return({ version: Gem::Version.new('8.10.4') })

      expect { model.esql("FROM #{TestIndex.name} | LIMIT 10") }
        .to raise_error(ActiveRecord::StatementInvalid, /ES\|QL requires Elasticsearch >= 8.11/)
    end

    it 'forwards an explicit allow_partial_results argument' do
      query = capture_esql_query do
        model.esql("FROM #{TestIndex.name} | LIMIT 10", allow_partial_results: false)
      end

      expect(query.query_arguments[:allow_partial_results]).to be(false)
    end

    it 'does not send an allow_partial_results argument by default' do
      query = capture_esql_query { model.esql("FROM #{TestIndex.name} | LIMIT 10") }

      expect(query.query_arguments).not_to have_key(:allow_partial_results)
    end

    it 'builds an ES|QL query from the provided string' do
      query = capture_esql_query { model.esql("FROM #{TestIndex.name} | LIMIT 10") }

      expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_ESQL)
      expect(query.body).to eq({ query: "FROM #{TestIndex.name} | LIMIT 10" })
      expect(query.gate).to eq('esql.query')
    end

    it 'always provides all source columns' do
      query = capture_esql_query { model.esql("FROM #{TestIndex.name} | LIMIT 10") }

      expect(query.columns).to eq(model.source_column_names)
    end

    it 'instruments the query with the model name' do
      model.source_column_names

      allow(model).to receive(:connection).and_return(connection_stub)
      expect(connection_stub).to receive(:exec_query)
                                   .with(anything, "#{model.name} ES|QL")
                                   .and_return(ElasticsearchRecord::Result.empty)

      model.esql("FROM #{TestIndex.name} | LIMIT 10")
    end

    # the query is dispatched through the PUBLIC +exec_query+ - the former +internal_exec_query+
    # call was a NoMethodError, since rails 7.1 moved that method below the +private+ keyword.
    # The +async:+ flag went away with it: +exec_query+ does not accept one.
    # see @ ActiveRecord::ConnectionAdapters::DatabaseStatements#exec_query
    it 'does not accept an async flag' do
      expect { model.esql("FROM #{TestIndex.name} | LIMIT 10", async: true) }.to raise_error(ArgumentError)
    end

    it 'executes the query without instantiating records' do
      result = model.esql("FROM #{TestIndex.name} | LIMIT 10")

      expect(result).to be_a(ElasticsearchRecord::Result)
      expect(result.response['values'].size).to eq(3)
    end

    # an ES|QL response is TABULAR ('columns' + 'values') - it carries no 'hits' node and no
    # 'total', so the transferred rows are all the +Result+ has to go by.
    # see @ ElasticsearchRecord::Result#_tabular?
    it 'resolves the tabular response through the result' do
      result = model.esql("FROM #{TestIndex.name} | KEEP name | SORT name")

      expect(result.length).to eq(3)
      expect(result.total).to eq(3)
      expect(result.rows).to eq([['alpha'], ['beta'], ['gamma']])
      expect(result.results).to eq([{ 'name' => 'alpha' }, { 'name' => 'beta' }, { 'name' => 'gamma' }])
    end
  end

  describe '.msearch' do
    # see the note at +.esql+ - +msearch+ dispatches through the same public +exec_query+
    let(:connection_stub) { instance_double(ActiveRecord::ConnectionAdapters::ElasticsearchAdapter) }

    def capture_msearch_query
      model.source_column_names

      captured = nil
      allow(model).to receive(:connection).and_return(connection_stub)
      allow(connection_stub).to receive(:exec_query) do |query, *_args, **_opts|
        captured = query
        ElasticsearchRecord::Result.empty
      end

      yield

      captured
    end

    it 'builds a msearch query against the table_name' do
      query = capture_msearch_query { model.msearch([{ query: { match_all: {} } }]) }

      expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_MSEARCH)
      expect(query.index).to eq(model.table_name)
    end

    it 'wraps each provided query within a search node' do
      queries = [{ query: { match_all: {} } }, { query: { term: { name: 'alpha' } } }]

      query = capture_msearch_query { model.msearch(queries) }

      expect(query.body).to eq(queries.map { |q| { search: q } })
    end

    it 'always provides all source columns' do
      query = capture_msearch_query { model.msearch([{ query: { match_all: {} } }]) }

      expect(query.columns).to eq(model.source_column_names)
    end

    it 'instruments the query with the model name' do
      model.source_column_names

      allow(model).to receive(:connection).and_return(connection_stub)
      expect(connection_stub).to receive(:exec_query)
                                   .with(anything, "#{model.name} Msearch")
                                   .and_return(ElasticsearchRecord::Result.empty)

      model.msearch([{ query: { match_all: {} } }])
    end

    # see the note at +.esql+ - the +async:+ flag went away with +internal_exec_query+
    it 'does not accept an async flag' do
      expect { model.msearch([{ query: { match_all: {} } }], async: true) }.to raise_error(ArgumentError)
    end

    it 'executes the queries without instantiating records' do
      result = model.msearch([{ query: { match_all: {} } }, { query: { term: { name: 'alpha' } } }])

      expect(result).to be_a(ElasticsearchRecord::Result)
      expect(result.length).to eq(2)
      expect(result.to_a.map(&:total)).to eq([3, 1])
    end
  end

  describe '.search' do
    it 'instantiates records from the provided query arguments' do
      records = model.search(body: { query: { term: { name: 'alpha' } } })

      expect(records).to all(be_a(model))
      expect(records.map(&:name)).to eq(['alpha'])
    end

    it 'resolves through #find_by_query' do
      expect(model).to receive(:find_by_query).with({ body: { query: { match_all: {} } } })

      model.search(body: { query: { match_all: {} } })
    end

    it 'extracts the options from the provided args' do
      expect(model).to receive(:find_by_query).with({ size: 1 })

      model.search(:ignored, { size: 1 })
    end

    it 'resolves all records without any provided args' do
      expect(model.search.map(&:name)).to match_array(%w[alpha beta gamma])
    end

    # PLEASE NOTE: the +Elasticsearch::DSL+ gem is NOT a dependency of this project. Without it
    # the +require+ raises a LoadError, which +search+ rescues by falling back to the trailing
    # options-hash - a provided block is then SILENTLY ignored.
    it 'ignores a provided block without the elasticsearch-dsl gem' do
      skip 'the elasticsearch-dsl gem is installed' if dsl_available?

      expect(model.search { query { match name: 'alpha' } }.map(&:name)).to match_array(%w[alpha beta gamma])
    end

    xit 'builds the query from a provided block with the elasticsearch-dsl gem' do
      skip 'the elasticsearch-dsl gem is not installed' unless dsl_available?

      expect(model.search { query { match name: 'alpha' } }.map(&:name)).to eq(['alpha'])
    end
  end

  describe '._query_by_msearch' do
    it 'returns a single result holding one sub-result per provided arel' do
      result = model._query_by_msearch([model.where(name: 'alpha').arel, model.all.arel])

      expect(result).to be_a(ElasticsearchRecord::Result)
      expect(result.length).to eq(2)
      expect(result.to_a).to all(be_a(ElasticsearchRecord::Result))
      expect(result.to_a.map(&:total)).to eq([1, 3])
    end

    it 'resolves the RAW results of each provided arel' do
      result = model._query_by_msearch([model.where(active: false).arel])

      expect(result.to_a.first.results.map { |hit| hit['name'] }).to eq(['beta'])
    end

    it 'does not instantiate any record' do
      result = model._query_by_msearch([model.all.arel])

      expect(result.to_a.first.results).to all(be_a(Hash))
    end

    # +select_multiple+ builds its own msearch query and does NOT forward any columns -
    # so the sub-results resolve the RAW +_source+ instead of a column-mapped row.
    it 'does not provide any columns' do
      result = model._query_by_msearch([model.all.arel])

      expect(result.columns).to eq([])
      expect(result.to_a.first.columns).to eq([])
    end

    it 'instruments the query with the model name' do
      allow(model.connection).to receive(:select_multiple).and_call_original

      model._query_by_msearch([model.all.arel])

      expect(model.connection).to have_received(:select_multiple).with(anything, "#{model.name} Msearch", async: false)
    end

    it 'raises for an async call' do
      expect {
        model._query_by_msearch([model.all.arel], async: true)
      }.to raise_error(StandardError, /ASYNC api calls are not supported/)
    end
  end
end
