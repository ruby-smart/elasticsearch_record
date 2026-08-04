# frozen_string_literal: true

# Covers the relation chain methods of +ElasticsearchRecord::Relation::QueryMethods+.
#
# These are the ES-specific counterparts to ActiveRecord's chain methods - they never build SQL
# fragments but fill the relation's +kind+ / +query+ / +aggs+ / +configure+ values, which
# +#build_arel+ then hands to the custom Arel nodes and the ES visitor compiles into an
# +ElasticsearchRecord::Query+.
#
# Every example therefore asserts on the COMPILED query (+model.all...to_sql+ returns a
# +ElasticsearchRecord::Query+, not a String) or on the relation value itself.
#
# PLEASE NOTE: the projection guard of the very same module (+#select+ / +#pluck+ / metadata
# fields) is covered separately in +query_methods_spec.rb+.
#
# see @ ElasticsearchRecord::Relation::QueryMethods
# see @ ElasticsearchRecord::Relation::ValueMethods
# see @ Arel::Visitors::ElasticsearchQuery
RSpec.describe ElasticsearchRecord::Relation::QueryMethods, :elasticsearch do
  # PLEASE NOTE: the +:elasticsearch+ tag skips these examples through a +before(:each)+ hook
  # (see spec_helper.rb) - so the index setup must NOT run in a +before(:all)+, which would
  # execute before that hook and blow up instead of skipping.
  #
  # No documents are inserted and no example mutates the index: every one of them asserts on the
  # BUILT query, not on results. The index itself is still required, since the column resolution
  # (+searchable_column_names+) reads the mapping from the cluster.
  #
  # IMPORTANT: the setup is therefore IDEMPOTENT instead of a per-example create & drop. Recreating
  # the index for each of the ~100 examples made the suite flaky on a busy (shared) cluster - the
  # create / drop churn intermittently raced with the following mapping lookup.
  before { TestIndex.create! unless TestIndex.exists? }

  after(:all) { TestIndex.drop! if ElasticsearchSpec.available? }

  subject(:relation) { model.all }

  let(:model) do
    Class.new(ElasticsearchRecord::Base) {
      def self.name = 'QueryMethodsChainSpecModel'
    }.tap { |klass|
      klass.table_name = TestIndex.name
      klass.reset_column_information
    }
  end

  # the compiled query body - the whole point of every chain method below
  def body_for(rel)
    rel.to_sql.body
  end

  ########################
  # UNSUPPORTED / GUARDS #
  ########################

  describe '#joins' do
    # Elasticsearch has no joins - the visitor would raise on the JoinSource anyway, but failing
    # here keeps the error at the place the user wrote it
    it 'raises for any provided argument' do
      expect { relation.joins(:other) }.to raise_error(ActiveRecord::StatementInvalid, 'Unsupported method "joins"')
    end

    it 'raises without any argument' do
      expect { relation.joins }.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  ########
  # KIND #
  ########

  describe '#kind' do
    it 'sets the kind value' do
      expect(relation.kind(:dis_max).kind_value).to eq(:dis_max)
    end

    it 'casts a provided String to a Symbol' do
      expect(relation.kind('bool').kind_value).to eq(:bool)
    end

    it 'overwrites a previously set kind' do
      expect(relation.kind(:bool).kind(:dis_max).kind_value).to eq(:dis_max)
    end

    # a kind alone builds NO query node - the visitor needs at least one query or where clause
    # see @ Arel::Visitors::ElasticsearchQuery#visit_Query
    it 'does not build a query node on its own' do
      expect(body_for(relation.kind(:dis_max))).to eq({})
    end

    it 'spawns a new relation' do
      spawned = relation.kind(:bool)

      expect(spawned).not_to equal(relation)
      expect(relation.kind_value).to be_nil
    end
  end

  describe '#kind!' do
    it 'mutates the same relation' do
      expect(relation.kind!(:bool)).to equal(relation)
      expect(relation.kind_value).to eq(:bool)
    end

    # +kind_value=+ asserts the mutability - a loaded relation can no longer be changed
    it 'raises on an already loaded relation' do
      relation.load

      expect { relation.kind!(:bool) }.to raise_error(ActiveRecord::ImmutableRelation)
    end
  end

  #############
  # CONFIGURE #
  #############

  describe '#configure' do
    it 'merges a provided Hash into the body' do
      expect(body_for(relation.configure({ from: 5, size: 2 }))).to eq({ from: 5, size: 2 })
    end

    it 'assigns a provided key & value' do
      expect(body_for(relation.configure(:size, 3))).to eq({ size: 3 })
    end

    # +configure+ is resolved LAST by the visitor, so it wins over anything built before
    it 'overwrites a previously built value' do
      expect(body_for(relation.limit(10).configure(:size, 999))).to eq({ size: 999 })
    end

    # a nil value DELETES the key - the documented way to force-remove a built setting
    it 'removes a key for a provided nil value' do
      expect(body_for(relation.limit(10).configure({ size: nil }))).to eq({})
    end

    it 'removes an ActiveRecord-built value' do
      expect(body_for(relation.order(name: :desc).configure({ sort: nil }))).to eq({})
    end

    # CAVEAT: AR's +check_if_method_has_arguments!+ mutates the args (+flatten!+ & +compact_blank!+),
    # so a blank value is REMOVED from them before +configure!+ ever sees it. The remaining single
    # argument matches none of the branches - the call is silently dropped. The documented
    # "provide a nil to remove the key" therefore only works through the HASH form above.
    # see @ ActiveRecord::QueryMethods#check_if_method_has_arguments!
    it 'silently ignores a nil value in the two-argument form' do
      expect(relation.configure(:size, nil).configure_value).to eq({})
      expect(body_for(relation.limit(10).configure(:size, nil))).to eq({ size: 10 })
    end

    # +compact_blank!+ drops every BLANK value - not just nil
    it 'silently ignores a false value in the two-argument form' do
      expect(relation.configure(:_source, false).configure_value).to eq({})
    end

    it 'keeps a zero value in the two-argument form' do
      expect(relation.configure(:size, 0).configure_value).to eq({ size: 0 })
    end

    it 'keeps a false value provided through the Hash form' do
      expect(body_for(relation.configure({ _source: false }))).to eq({ _source: false })
    end

    it 'raises without any argument' do
      expect { relation.configure }.to raise_error(ArgumentError, /must contain arguments/)
    end

    # only the 1-Hash and the 2-argument forms are handled - anything else is silently ignored
    it 'ignores a call with more than two arguments' do
      expect(relation.configure(:a, :b, :c).configure_value).to eq({})
    end

    it 'spawns a new relation' do
      expect(relation.configure(:size, 3)).not_to equal(relation)
      expect(relation.configure_value).to eq({})
    end

    # the special key escapes the body and reaches the query object itself
    # see @ Arel::Collectors::ElasticsearchQuery#assign
    context 'with the :__query__ key' do
      it 'sets a query-level value instead of a body value' do
        query = relation.configure(:__query__, refresh: true).to_sql

        expect(query.refresh).to be(true)
        expect(query.body).to eq({})
      end

      # PLEASE NOTE: the :__query__ values ACCUMULATE into an Array - unlike every other key,
      # which is merged (and therefore overwritten)
      it 'accumulates multiple calls into an Array' do
        rel = relation.configure(:__query__, refresh: true).configure(:__query__, timeout: '1m')

        expect(rel.configure_value).to eq({ __query__: [{ refresh: true }, { timeout: '1m' }] })
      end

      it 'claims every accumulated value' do
        query = relation.configure(:__query__, refresh: true).configure(:__query__, timeout: '1m').to_sql

        expect(query.refresh).to be(true)
        expect(query.timeout).to eq('1m')
      end
    end
  end

  describe '#configure!' do
    it 'mutates the same relation' do
      expect(relation.configure!(:size, 3)).to equal(relation)
      expect(relation.configure_value).to eq({ size: 3 })
    end
  end

  describe '#refresh' do
    it 'sets the query refresh' do
      expect(relation.refresh.to_sql.refresh).to be(true)
    end

    it 'accepts an explicit false' do
      expect(relation.refresh(false).to_sql.refresh).to be(false)
    end

    # it is a +configure(:__query__, ...)+ shortcut - never a body value
    it 'does not write into the body' do
      expect(body_for(relation.refresh)).to eq({})
    end
  end

  describe '#timeout' do
    it 'sets the query timeout' do
      expect(relation.timeout('1m').to_sql.timeout).to eq('1m')
    end

    it 'defaults to true' do
      expect(relation.timeout.to_sql.timeout).to be(true)
    end

    it 'does not write into the body' do
      expect(body_for(relation.timeout('1m'))).to eq({})
    end
  end

  ################
  # AGGREGATIONS #
  ################

  describe '#aggregate' do
    it 'builds an aggregation from a name & definition' do
      expect(body_for(relation.aggregate(:total, { sum: { field: :count } })))
        .to eq({ aggs: { total: { sum: { field: :count } } } })
    end

    it 'accepts a String name' do
      expect(body_for(relation.aggregate('total', { sum: { field: :count } })))
        .to eq({ aggs: { 'total' => { sum: { field: :count } } } })
    end

    it 'builds multiple aggregations from a Hash' do
      expect(body_for(relation.aggregate({ total: { sum: { field: :count } }, avg: { avg: { field: :count } } })))
        .to eq({ aggs: { total: { sum: { field: :count } }, avg: { avg: { field: :count } } } })
    end

    it 'appends to previously built aggregations' do
      rel = relation.aggregate(:total, { sum: { field: :count } }).aggregate(:avg, { avg: { field: :count } })

      expect(body_for(rel)).to eq({ aggs: { total: { sum: { field: :count } }, avg: { avg: { field: :count } } } })
    end

    it 'raises for an unsupported argument type' do
      expect { relation.aggregate(123, {}) }
        .to raise_error(ArgumentError, 'Unsupported argument type for aggregate: 123')
    end

    it 'raises without any argument' do
      expect { relation.aggregate }.to raise_error(ArgumentError, /must contain arguments/)
    end

    it 'is aliased as #aggs' do
      expect(body_for(relation.aggs(:total, { sum: { field: :count } })))
        .to eq({ aggs: { total: { sum: { field: :count } } } })
    end
  end

  ##################
  # QUERY BUILDERS #
  ##################

  describe '#query' do
    it 'sets the kind & builds the query node' do
      rel = relation.query(:bool, { filter: { term: { name: 'x' } } })

      expect(rel.kind_value).to eq(:bool)
      expect(body_for(rel)).to eq({ query: { bool: { filter: [{ term: { name: 'x' } }] } } })
    end

    it 'sets a non-bool kind' do
      rel = relation.query(:dis_max, { queries: { term: { name: 'x' } } })

      expect(rel.kind_value).to eq(:dis_max)
      expect(body_for(rel)).to eq({ query: { dis_max: { queries: [{ term: { name: 'x' } }] } } })
    end

    # trailing options are the clause +opts+ - they are assigned next to the clause, on the kind level
    it 'assigns trailing options on the kind level' do
      rel = relation.query(:bool, { should: { term: { name: 'x' } } }, minimum_should_match: 1)

      expect(body_for(rel))
        .to eq({ query: { bool: { should: [{ term: { name: 'x' } }], minimum_should_match: 1 } } })
    end

    it 'raises without any argument' do
      expect { relation.query }.to raise_error(ArgumentError, /must contain arguments/)
    end
  end

  # all four share the very same implementation - only the clause key differs
  { filter: :filter, must: :must, must_not: :must_not, should: :should }.each do |method, key|
    describe "##{method}" do
      it "builds a #{key} clause" do
        expect(body_for(relation.public_send(method, { term: { name: 'x' } })))
          .to eq({ query: { bool: { key => [{ term: { name: 'x' } }] } } })
      end

      # every conditional method forces the default kind
      it 'defaults the kind to :bool' do
        expect(relation.public_send(method, { term: { name: 'x' } }).kind_value).to eq(:bool)
      end

      it 'keeps an explicitly set kind' do
        expect(relation.kind(:dis_max).public_send(method, { term: { name: 'x' } }).kind_value).to eq(:dis_max)
      end

      it 'appends to an existing clause of the same key' do
        rel = relation.public_send(method, { term: { name: 'x' } }).public_send(method, { term: { count: 1 } })

        expect(body_for(rel))
          .to eq({ query: { bool: { key => [{ term: { name: 'x' } }, { term: { count: 1 } }] } } })
      end

      it 'assigns trailing options on the kind level' do
        rel = relation.public_send(method, { term: { name: 'x' } }, _name: 'annotated')

        expect(body_for(rel))
          .to eq({ query: { bool: { key => [{ term: { name: 'x' } }], _name: 'annotated' } } })
      end

      it 'raises without any argument' do
        expect { relation.public_send(method) }.to raise_error(ArgumentError, /must contain arguments/)
      end

      it 'spawns a new relation' do
        expect(relation.public_send(method, { term: { name: 'x' } })).not_to equal(relation)
      end
    end
  end

  it 'combines different clause keys within a single bool node' do
    rel = relation.filter({ term: { name: 'x' } }).must_not({ term: { count: 1 } })

    expect(body_for(rel)).to eq({
                                  query: {
                                    bool: {
                                      filter:   [{ term: { name: 'x' } }],
                                      must_not: [{ term: { count: 1 } }]
                                    }
                                  }
                                })
  end

  # +build_query_clause+ guards against clauses that would produce an invalid ES query
  describe 'blank clause data' do
    it 'raises for a blank value' do
      expect { relation.aggregate(:total, nil) }
        .to raise_error(ArgumentError, /Unable to build query clause for 'total' without any data @ QueryMethodsChainSpecModel/)
    end

    # PLEASE NOTE: AR's +check_if_method_has_arguments!+ strips the blank values from the args
    # BEFORE the clause is built, so a nil-only clause never reaches the guard above - the call
    # fails on the arity of the +!+-method instead.
    # see @ ActiveRecord::QueryMethods#check_if_method_has_arguments!
    it 'raises on the arity for a nil-only Array' do
      expect { relation.filter([nil]) }
        .to raise_error(ArgumentError, /wrong number of arguments \(given 0, expected 1\+\)/)
    end
  end

  #########
  # WHERE #
  #########

  describe '#where' do
    it 'builds a term filter from a Hash' do
      expect(body_for(relation.where(name: 'x')))
        .to eq({ query: { bool: { filter: [{ term: { 'name' => 'x' } }] } } })
    end

    it 'builds a terms filter from an Array value' do
      expect(body_for(relation.where(name: %w[x y])))
        .to eq({ query: { bool: { filter: [{ terms: { 'name' => %w[x y] } }] } } })
    end

    it 'defaults the kind to :bool' do
      expect(relation.where(name: 'x').kind_value).to eq(:bool)
    end

    it 'resolves an attribute alias' do
      model.alias_attribute :title, :name

      expect(body_for(relation.where(title: 'x')))
        .to eq({ query: { bool: { filter: [{ term: { 'name' => 'x' } }] } } })
    end

    # metadata fields ARE searchable - unlike within a projection
    it 'accepts a metadata field' do
      expect(body_for(relation.where(_id: 'abc')))
        .to eq({ query: { bool: { filter: [{ term: { '_id' => 'abc' } }] } } })
    end

    it 'raises for an unknown attribute' do
      expect { relation.where(unknown_field: 1) }.to raise_error(
        ActiveRecord::UnknownAttributeReference, /unknown searchable attributes: "unknown_field"/
      ) { |error|
        # the message points to the custom-query alternative
        expect(error.message).to include("QueryMethodsChainSpecModel.filter('unknown_field' => '...')")
      }
    end

    # a String condition is a SQL fragment - there is no SQL here
    it 'raises for a provided String' do
      expect { relation.where('name = 1') }
        .to raise_error(ArgumentError, /Unsupported or unresolved argument class 'String'/)
    end

    context 'with a clause-key prefix' do
      # the prefix forwards RAW to the matching clause method - no attribute check, no manipulation
      %i[filter must must_not should].each do |key|
        it "forwards :#{key} to ##{key}!" do
          expect(body_for(relation.where(key, { term: { name: 'x' } })))
            .to eq({ query: { bool: { key => [{ term: { name: 'x' } }] } } })
        end
      end

      it 'skips the searchable-attribute check' do
        expect { relation.where(:filter, { term: { unknown_field: 'x' } }) }.not_to raise_error
      end

      it 'raises for an unsupported prefix' do
        expect { relation.where(:nope, {}) }.to raise_error(
          ArgumentError, "Unsupported prefix type 'nope'. Allowed types are: :filter, :must, :must_not, :should"
        )
      end
    end

    context 'with a nested Array' do
      it 'builds a clause per entry' do
        rel = relation.where([[:filter, { term: { name: 'x' } }], [:must_not, { term: { name: 'y' } }]])

        expect(body_for(rel)).to eq({
                                      query: {
                                        bool: {
                                          filter:   [{ term: { name: 'x' } }],
                                          must_not: [{ term: { name: 'y' } }]
                                        }
                                      }
                                    })
      end

      it 'unwraps a flat Array into a single clause' do
        expect(body_for(relation.where([:filter, { term: { name: 'x' } }])))
          .to eq({ query: { bool: { filter: [{ term: { name: 'x' } }] } } })
      end
    end

    describe ':none' do
      # a failed query is not an error - it swaps in a body that matches nothing
      it 'fails the query' do
        expect(relation.where(:none).to_sql.status).to eq(ElasticsearchRecord::Query::STATUS_FAILED)
      end

      it 'builds the same query as #none' do
        expect(body_for(relation.where(:none))).to eq(body_for(relation.none))
      end
    end
  end

  describe '#none!' do
    it 'fails the query through the :__query__ status' do
      query = relation.none.to_sql

      expect(query.status).to eq(ElasticsearchRecord::Query::STATUS_FAILED)
      expect(query.body).to eq(ElasticsearchRecord::Query::FAILED_BODIES[ElasticsearchRecord::Query::TYPE_SEARCH])
    end
  end

  ###########
  # UNSCOPE #
  ###########

  describe '#unscope' do
    # the ES-specific values are added to the valid unscoping values
    # see @ ElasticsearchRecord::Relation::ValueMethods#_valid_unscoping_values
    it 'removes the kind value' do
      expect(relation.kind(:bool).unscope(:kind).kind_value).to be_nil
    end

    it 'removes the query clauses' do
      expect(body_for(relation.filter({ term: { name: 'x' } }).unscope(:query))).to eq({})
    end

    it 'removes the aggregations' do
      expect(body_for(relation.aggregate(:total, { sum: { field: :count } }).unscope(:aggs))).to eq({})
    end

    it 'removes the configuration' do
      expect(body_for(relation.configure(:size, 3).unscope(:configure))).to eq({})
    end

    # a Hash removes a SINGLE clause instead of the whole value
    it 'removes a single query clause through a Hash' do
      rel = relation
              .filter({ term: { name: 'x' } })
              .filter({ term: { count: 1 } })
              .unscope(filter: { term: { name: 'x' } })

      expect(body_for(rel)).to eq({ query: { bool: { filter: [{ term: { count: 1 } }] } } })
    end

    it 'raises for an invalid unscoping Symbol' do
      expect { relation.unscope(:nope) }
        .to raise_error(ArgumentError, /Called unscope\(\) with invalid unscoping argument ':nope'/)
    end

    it 'raises for an unrecognized scoping' do
      expect { relation.unscope('str') }.to raise_error(ArgumentError, /Unrecognized scoping/)
    end
  end

  ######
  # OR #
  ######

  # CAVEAT: +QueryClauseTree#or+ builds an +Arel::Nodes::Grouping+, and the ES visitor FAILS every
  # grouping (there is no Elasticsearch equivalent, see the commented-out +visit_Arel_Nodes_Or+).
  # So an +#or+ silently compiles into a query that matches NOTHING - pinned here as the current
  # behaviour, not as a desired one.
  # see @ Arel::Visitors::ElasticsearchQuery#visit_Arel_Nodes_Grouping
  describe '#or' do
    it 'compiles into a failed query for two query clauses' do
      rel = relation.filter({ term: { name: 'x' } }).or(relation.filter({ term: { name: 'y' } }))

      expect(rel.to_sql.status).to eq(ElasticsearchRecord::Query::STATUS_FAILED)
    end

    it 'compiles into a failed query for two where clauses' do
      rel = relation.where(name: 'x').or(relation.where(name: 'y'))

      expect(rel.to_sql.status).to eq(ElasticsearchRecord::Query::STATUS_FAILED)
    end

    it 'wraps the clauses into a grouped Or node' do
      rel  = relation.filter({ term: { name: 'x' } }).or(relation.filter({ term: { name: 'y' } }))
      node = rel.query_clause.ast[0][1]

      expect(node).to be_a(Arel::Nodes::Grouping)
      expect(node.expr).to be_a(Arel::Nodes::Or)
    end

    # a common clause on both sides is kept outside the Or - only the differing parts are grouped
    it 'keeps an identical clause without grouping it' do
      rel = relation.filter({ term: { name: 'x' } }).or(relation.filter({ term: { name: 'x' } }))

      expect(body_for(rel)).to eq({ query: { bool: { filter: [{ term: { name: 'x' } }] } } })
      expect(rel.to_sql.status).not_to eq(ElasticsearchRecord::Query::STATUS_FAILED)
    end
  end

  ##############
  # BUILD_AREL #
  ##############

  describe '#build_arel' do
    it 'forwards every ES value to the Arel nodes' do
      rel = relation
              .kind(:bool)
              .filter({ term: { name: 'x' } })
              .aggregate(:total, { sum: { field: :count } })
              .configure(:size, 3)

      expect(body_for(rel)).to eq({
                                    query: { bool: { filter: [{ term: { name: 'x' } }] } },
                                    aggs:  { total: { sum: { field: :count } } },
                                    size:  3
                                  })
    end

    it 'builds a plain query without any ES value' do
      expect(body_for(relation)).to eq({})
    end

    it 'keeps working together with the ActiveRecord chain methods' do
      rel = relation.filter({ term: { name: 'x' } }).limit(5).offset(10).order(name: :desc)

      expect(body_for(rel)).to eq({
                                    query: { bool: { filter: [{ term: { name: 'x' } }] } },
                                    sort:  { 'name' => :desc },
                                    size:  5,
                                    from:  10
                                  })
    end
  end
end
