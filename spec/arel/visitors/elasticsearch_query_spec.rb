# frozen_string_literal: true

# Covers every +visit_*+ method of +Arel::Visitors::ElasticsearchQuery+.
#
# The visitor is the CRUD half of +Arel::Visitors::Elasticsearch+ (the DDL half lives in
# +Arel::Visitors::ElasticsearchSchema+). It never produces SQL - it +claim+s on an
# +Arel::Collectors::ElasticsearchQuery+, which IS the +ElasticsearchRecord::Query+ that the
# adapter later dispatches to the API. So every example below asserts on the compiled query
# (+#type+, +#index+, +#body+, +#columns+, +#status+, +#refresh+) instead of on a String.
#
# PLEASE NOTE: these specs never touch a cluster - the visitor is plain Ruby. The only
# collaborator is the connection, and it is only used for +#quote+ (update scripts).
#
# All +visit_*+ methods are PRIVATE - they are reached through +#compile+ (which dispatches via
# +accept+). The handful of leaf visits that only convert a value (raw / attribute / bind) are
# exercised through +send(:visit, ...)+, since no AST shape reaches them in isolation.
#
# see @ Arel::Visitors::ElasticsearchQuery
# see @ Arel::Visitors::ElasticsearchBase
RSpec.describe Arel::Visitors::Elasticsearch do
  subject(:visitor) { described_class.new(connection) }

  let(:connection) do
    instance_double(ActiveRecord::ConnectionAdapters::ElasticsearchAdapter).tap do |conn|
      allow(conn).to receive(:quote) { |value| value.is_a?(String) ? "'#{value}'" : value.to_s }
    end
  end

  let(:table) { Arel::Table.new('bar') }

  # +visit_Arel_Nodes_SelectCore+ reads +source_column_names+ off the table's +@klass+ to provide
  # the "full-column-definition" default. A plain +Arel::Table+ carries no klass, so this stub
  # stands in for the model wherever the column default matters.
  let(:model_table) do
    klass = Class.new do
      def self.source_column_names = %w[name count]

      # required by +Arel::Table+ / +Arel::Table#[]+
      def self.type_caster = nil
      def self.attribute_aliases = {}
    end

    Arel::Table.new('bar', klass: klass)
  end

  # the shape the predicate builder produces: +Arel::Nodes::Equality(attribute, QueryAttribute)+
  def query_attribute(name, value, type = ActiveModel::Type::String.new)
    ActiveRecord::Relation::QueryAttribute.new(name, value, type)
  end

  ######################
  # CORE VISITS (CRUD) #
  ######################

  describe '#visit_Arel_Nodes_SelectStatement' do
    it 'claims a search type & the index' do
      query = visitor.compile(Arel::SelectManager.new(table).ast)

      expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_SEARCH)
      expect(query.index).to eq('bar')
      expect(query.body).to eq({})
    end

    it 'resolves cores, orders, limit & offset into the body' do
      manager = Arel::SelectManager.new(table)
      manager.kind(:bool)
      manager.query([[:filter, { term: { name: 'x' } }]])
      manager.order(table['name'].desc)
      manager.take(10)
      manager.skip(5)

      query = visitor.compile(manager.ast)

      expect(query.body).to eq({
                                 query: { bool: { filter: [{ term: { name: 'x' } }] } },
                                 sort:  { 'name' => :desc },
                                 size:  10,
                                 from:  5
                               })
    end

    # +configure+ is resolved LAST on purpose - it must be able to overwrite everything before it
    it 'lets configure overwrite a previously resolved value' do
      manager = Arel::SelectManager.new(table)
      manager.take(10)
      manager.configure({ size: 999 })

      expect(visitor.compile(manager.ast).body).to eq({ size: 999 })
    end
  end

  describe '#visit_Arel_Nodes_UpdateStatement' do
    subject(:query) { visitor.compile(manager.ast) }

    let(:manager) do
      select = Arel::SelectManager.new(table)
      select.where(Arel::Nodes::Equality.new(table['name'], query_attribute('name', 'x')))
      select.compile_update([[table['title'], query_attribute('title', 'hello')]], 'id')
    end

    it 'claims an update_by_query type & the index' do
      expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_UPDATE_BY_QUERY)
      expect(query.index).to eq('bar')
    end

    # updates are only visible to a following search once the index was refreshed
    it 'forces a refresh' do
      expect(query.refresh).to be(true)
    end

    it 'builds an inline script from the assignments' do
      expect(query.body[:script]).to eq({ inline: "ctx._source.title = 'hello'" })
    end

    it 'joins multiple assignments with a semicolon' do
      select  = Arel::SelectManager.new(table)
      updates = [[table['title'], query_attribute('title', 'hello')],
                 [table['count'], query_attribute('count', 5, ActiveModel::Type::Integer.new)]]

      body = visitor.compile(select.compile_update(updates, 'id').ast).body

      expect(body[:script]).to eq({ inline: "ctx._source.title = 'hello'; ctx._source.count = 5" })
    end

    it 'resolves the where clauses into the search query' do
      expect(query.body[:query]).to eq({ bool: { filter: [{ term: { 'name' => 'x' } }] } })
    end

    # PLEASE NOTE: +limit+ becomes +max_docs+ here - NOT +size+ (which is a search-only setting)
    it 'maps the limit to max_docs' do
      manager.ast.limit = Arel::Nodes::Limit.new(7)

      expect(query.body[:max_docs]).to eq(7)
    end

    it 'lets configure unset the forced refresh' do
      manager.configure({ __query__: { refresh: nil } })

      expect(query.refresh).to be_nil
    end

    # the single-record path never reaches Arel - it goes straight through +ModelApi+
    # see @ ElasticsearchRecord::Persistence#_update_record
    it 'raises for a plain table relation (the single-record shape)' do
      expect { visitor.compile(Arel::Nodes::UpdateStatement.new(table)) }
        .to raise_error(NotImplementedError)
    end
  end

  describe '#visit_Arel_Nodes_DeleteStatement' do
    subject(:query) { visitor.compile(manager.ast) }

    let(:manager) do
      select = Arel::SelectManager.new(table)
      select.where(Arel::Nodes::Equality.new(table['name'], query_attribute('name', 'x')))
      select.compile_delete
    end

    it 'claims a delete_by_query type & the index' do
      expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_DELETE_BY_QUERY)
      expect(query.index).to eq('bar')
    end

    it 'forces a refresh' do
      expect(query.refresh).to be(true)
    end

    it 'resolves the where clauses into the search query' do
      expect(query.body).to eq({ query: { bool: { filter: [{ term: { 'name' => 'x' } }] } } })
    end

    it 'maps the limit to max_docs' do
      manager.ast.limit = Arel::Nodes::Limit.new(3)

      expect(query.body[:max_docs]).to eq(3)
    end

    it 'raises for a plain table relation (the single-record shape)' do
      expect { visitor.compile(Arel::Nodes::DeleteStatement.new(table)) }
        .to raise_error(NotImplementedError)
    end
  end

  # Regression specs for the rails 7.1 Arel changes.
  #
  # +Arel::Nodes::HomogeneousIn#column_name+ was removed, and +InsertManager#insert+ splits
  # "column => plain value" into statement columns and a ValuesList of raw (non attribute-shaped)
  # values. Both broke silently on the rails 7.1 upgrade and are pinned here.
  describe '#visit_Arel_Nodes_InsertStatement / #visit_Create' do
    let(:migrations_table) { Arel::Table.new('schema_migrations') }

    # NOTE: only plain values are exercised below - attribute-shaped values never reach this
    # visitor. +ElasticsearchRecord::Persistence#_insert_record+ unwraps them
    # (+transform_values(&:value)+) and bypasses Arel entirely. The only callers that build an
    # +InsertManager+ are +SchemaMigration#create_version+ & +InternalMetadata#create_entry+,
    # both of which pass plain scalars.
    context 'with plain values (the rails 7.1 SchemaMigration#create_version shape)' do
      # +Arel::InsertManager#insert+ splits a "column => plain value" Hash into the
      # statement columns & a ValuesList of raw values - the pairs are restored by
      # position in +#visit_Create+.
      it 'zips the values with the statement columns' do
        im = Arel::InsertManager.new(migrations_table)
        im.insert(migrations_table['version'] => '20221212122912')

        query = visitor.compile(im.ast)

        expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_CREATE)
        expect(query.index).to eq('schema_migrations')
        expect(query.body).to eq({ 'version' => '20221212122912' })
      end

      it 'keeps multiple columns in positional order' do
        im = Arel::InsertManager.new(migrations_table)
        im.insert([[migrations_table['version'], '20221212122912'], [migrations_table['direction'], 'up']])

        query = visitor.compile(im.ast)

        expect(query.body).to eq({ 'version' => '20221212122912', 'direction' => 'up' })
      end

      it 'forces a refresh' do
        im = Arel::InsertManager.new(migrations_table)
        im.insert(migrations_table['version'] => '20221212122912')

        expect(visitor.compile(im.ast).refresh).to be(true)
      end
    end

    # Attribute-shaped values never reach this visitor: +ElasticsearchRecord::Persistence#_insert_record+
    # unwraps them (+transform_values(&:value)+) and talks to the API directly, without ever building
    # an +InsertManager+. Pinned here so nobody "fixes" +visit_Create+ for a shape it never receives -
    # resolving the value would additionally collide with the +visit_ActiveModel_Attribute_FromUser+
    # alias, which maps to +visit_Struct_Attribute+ (the NAME, not the value).
    #
    # see @ ElasticsearchRecord::Persistence#_insert_record
    context 'with attribute values (never produced by this gem)' do
      it 'passes the raw attribute through untouched' do
        attribute = ActiveModel::Attribute.from_user('version', '20221212122912', ActiveModel::Type::String.new)

        im = Arel::InsertManager.new(migrations_table)
        im.insert(migrations_table['version'] => attribute)

        query = visitor.compile(im.ast)

        expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_CREATE)
        expect(query.body['version']).to be(attribute)
      end
    end

    # a failed query is NOT an error - it swaps in a body that matches nothing (SQL: 'where 1=0').
    # +FAILED_BODIES+ only covers the read types, so a failed create falls back to an empty body.
    it 'fails the query when no values were provided' do
      query = visitor.compile(Arel::InsertManager.new(migrations_table).ast)

      expect(query.status).to eq(ElasticsearchRecord::Query::STATUS_FAILED)
      expect(ElasticsearchRecord::Query::FAILED_BODIES).not_to have_key(ElasticsearchRecord::Query::TYPE_CREATE)
      expect(query.body).to eq({})
    end

    it 'raises for anything but a plain table relation' do
      statement          = Arel::Nodes::InsertStatement.new
      statement.relation = Arel::Nodes::JoinSource.new(table)

      expect { visitor.compile(statement) }.to raise_error(NotImplementedError)
    end
  end

  ##############################
  # SUBSTRUCTURE VISITS (CRUD) #
  ##############################

  describe '#visit_Arel_Nodes_SelectCore' do
    # Elasticsearch does not store nil-values, so a document simply omits those keys. Without the
    # "full-column-definition" default the missing attributes would not be accessible on the record.
    it 'claims the models source_column_names as column default' do
      expect(visitor.compile(Arel::SelectManager.new(model_table).ast).columns).to eq(%w[name count])
    end

    it 'leaves the columns empty for a table without a model' do
      expect(visitor.compile(Arel::SelectManager.new(table).ast).columns).to eq([])
    end

    it 'does not build a query node without queries or wheres' do
      expect(visitor.compile(Arel::SelectManager.new(table).ast).body).to eq({})
    end
  end

  describe '#visit_Query' do
    it 'defaults the kind to :bool for plain where clauses' do
      manager = Arel::SelectManager.new(table)
      manager.where(Arel::Nodes::Equality.new(table['name'], query_attribute('name', 'x')))

      expect(visitor.compile(manager.ast).body)
        .to eq({ query: { bool: { filter: [{ term: { 'name' => 'x' } }] } } })
    end

    it 'uses the provided kind' do
      manager = Arel::SelectManager.new(table)
      manager.kind(:dis_max)
      manager.query([[:queries, { term: { name: 'x' } }]])

      expect(visitor.compile(manager.ast).body)
        .to eq({ query: { dis_max: { queries: [{ term: { name: 'x' } }] } } })
    end

    # without a kind there is no node to nest into - the queries are silently dropped
    it 'skips the whole query node when neither a kind nor wheres exist' do
      manager = Arel::SelectManager.new(table)
      manager.query([[:filter, { term: { a: 1 } }]])

      expect(visitor.compile(manager.ast).body).to eq({})
    end

    it 'merges multiple queries of the same type into one Array' do
      manager = Arel::SelectManager.new(table)
      manager.kind(:bool)
      manager.query([[:filter, { term: { a: 1 } }], [:filter, { term: { b: 2 } }]])

      expect(visitor.compile(manager.ast).body)
        .to eq({ query: { bool: { filter: [{ term: { a: 1 } }, { term: { b: 2 } }] } } })
    end

    it 'combines queries with where clauses' do
      manager = Arel::SelectManager.new(table)
      manager.kind(:bool)
      manager.query([[:must, { match: { a: 1 } }]])
      manager.where(Arel::Nodes::Equality.new(table['name'], query_attribute('name', 'x')))

      expect(visitor.compile(manager.ast).body).to eq({
                                                        query: {
                                                          bool: {
                                                            must:   [{ match: { a: 1 } }],
                                                            filter: [{ term: { 'name' => 'x' } }]
                                                          }
                                                        }
                                                      })
    end

    # the opts of a query node are assigned on the KIND level - not inside the type's Array
    it 'assigns the query opts next to the query type' do
      manager = Arel::SelectManager.new(table)
      manager.kind(:bool)
      manager.query([[:should, { match: { a: 1 } }, { minimum_should_match: 1 }]])

      expect(visitor.compile(manager.ast).body).to eq({
                                                        query: {
                                                          bool: {
                                                            should:               [{ match: { a: 1 } }],
                                                            minimum_should_match: 1
                                                          }
                                                        }
                                                      })
    end
  end

  describe '#visit_Arel_Nodes_SelectKind' do
    # PLEASE NOTE: +#visit_Query+ unwraps the node itself (+visit(o.kind.expr)+), so this method is
    # only reached through a direct dispatch. It stays as the node's official visit.
    it 'unwraps the node to its expression' do
      expect(visitor.send(:visit, Arel::Nodes::SelectKind.new(:bool))).to eq(:bool)
    end
  end

  describe '#visit_Arel_Nodes_Comment' do
    # annotations are resolved inside the query node, so they need an existing kind
    it 'assigns the joined annotations as _name' do
      manager = Arel::SelectManager.new(table)
      manager.where(Arel::Nodes::Equality.new(table['name'], query_attribute('name', 'x')))
      manager.comment('hello', 'world')

      expect(visitor.compile(manager.ast).body[:query][:bool][:_name]).to eq('hello - world')
    end
  end

  describe '#visit_Aggs / #visit_Arel_Nodes_SelectAgg' do
    it 'assigns the aggregations' do
      manager = Arel::SelectManager.new(table)
      manager.aggs([[:total, { sum: { field: 'count' } }]])

      expect(visitor.compile(manager.ast).body).to eq({ aggs: { total: { sum: { field: 'count' } } } })
    end

    # +SelectAgg#right+ reduces an Array of Hashes into a single Hash
    it 'merges an Array value into a single aggregation' do
      manager = Arel::SelectManager.new(table)
      manager.aggs([[:total, [{ sum: { field: 'count' } }, { missing: 0 }]]])

      expect(visitor.compile(manager.ast).body)
        .to eq({ aggs: { total: { sum: { field: 'count' }, missing: 0 } } })
    end

    # opts are assigned on the TOP agg level (next to the named aggregations)
    it 'assigns the agg opts on the aggs level' do
      manager = Arel::SelectManager.new(table)
      manager.aggs([[:total, { sum: { field: 'count' } }, { meta: { unit: 'ms' } }]])

      expect(visitor.compile(manager.ast).body).to eq({
                                                        aggs: {
                                                          total: { sum: { field: 'count' } },
                                                          meta:  { unit: 'ms' }
                                                        }
                                                      })
    end

    it 'assigns multiple aggregations' do
      manager = Arel::SelectManager.new(table)
      manager.aggs([[:total, { sum: { field: 'count' } }], [:avg, { avg: { field: 'count' } }]])

      expect(visitor.compile(manager.ast).body)
        .to eq({ aggs: { total: { sum: { field: 'count' } }, avg: { avg: { field: 'count' } } } })
    end
  end

  describe '#visit_Selects' do
    def compile_projection(*projections)
      manager = Arel::SelectManager.new(model_table)
      projections.each { |projection| manager.project(projection) }

      visitor.compile(manager.ast)
    end

    context 'with a star projection' do
      # '*' means "all fields" - which is the Elasticsearch default, so nothing is assigned
      it 'does not restrict the _source' do
        query = compile_projection(Arel.star)

        expect(query.body).to eq({})
      end

      it 'keeps the column default claimed by the select core' do
        expect(compile_projection(Arel.star).columns).to eq(%w[name count])
      end
    end

    context 'with the COLUMNS_NONE marker' do
      # disables the +_source+ entirely - metadata fields are returned on the document level and
      # stay accessible. The empty columns make +Result#_results_from_hits+ return the raw document.
      it 'disables the _source' do
        expect(compile_projection(ElasticsearchRecord::Query::COLUMNS_NONE).body).to eq({ _source: false })
      end

      it 'clears the columns claimed by the select core' do
        expect(compile_projection(ElasticsearchRecord::Query::COLUMNS_NONE).columns).to eq([])
      end
    end

    context 'with the ONE_AS_ONE projection (exists? / any?)' do
      it 'disables the _source' do
        expect(compile_projection(ActiveRecord::FinderMethods::ONE_AS_ONE).body).to eq({ _source: false })
      end

      it 'claims a single "one" column' do
        expect(compile_projection(ActiveRecord::FinderMethods::ONE_AS_ONE).columns).to eq(%w[one])
      end
    end

    context 'with regular fields' do
      it 'restricts the _source & claims the columns' do
        query = compile_projection(model_table['name'])

        expect(query.body).to eq({ _source: ['name'] })
        expect(query.columns).to eq(%w[name])
      end

      # metadata fields are NOT part of the +_source+ - a +_source+-filter on them never matches
      it 'removes metadata fields from the _source but keeps them as columns' do
        query = compile_projection(model_table['name'], model_table['_id'])

        expect(query.body).to eq({ _source: ['name'] })
        expect(query.columns).to eq(%w[name _id])
      end

      it 'disables the _source when ONLY metadata fields were projected' do
        query = compile_projection(model_table['_id'])

        expect(query.body).to eq({ _source: false })
        expect(query.columns).to eq(%w[_id])
      end
    end
  end

  describe '#visit_Arel_Nodes_SelectConfigure' do
    it 'assigns each key of the provided Hash on the body' do
      manager = Arel::SelectManager.new(table)
      manager.configure({ size: 5, from: 10 })

      expect(visitor.compile(manager.ast).body).to eq({ size: 5, from: 10 })
    end

    # +nil+ values delete the key - this is how a previously assigned value is removed again
    it 'deletes a key for a provided nil value' do
      manager = Arel::SelectManager.new(table)
      manager.take(10)
      manager.configure({ size: nil })

      expect(visitor.compile(manager.ast).body).to eq({})
    end

    # the special key escapes the body and re-dispatches as a claim
    # see @ ElasticsearchRecord::Relation::QueryMethods#configure
    it 'claims query-level settings through the :__query__ key' do
      manager = Arel::SelectManager.new(table)
      manager.configure({ __query__: { refresh: true } })

      query = visitor.compile(manager.ast)

      expect(query.refresh).to be(true)
      expect(query.body).to eq({})
    end

    it 'ignores a blank configuration' do
      manager = Arel::SelectManager.new(table)
      manager.configure({})

      expect(visitor.compile(manager.ast).body).to eq({})
    end
  end

  describe '#visit_Arel_Nodes_Assignment' do
    def compile_assignment(attribute)
      select = Arel::SelectManager.new(table)

      visitor.compile(select.compile_update([[table['title'], attribute]], 'id').ast)
    end

    it 'quotes a regular value through the connection' do
      expect(compile_assignment(query_attribute('title', 'hello')).body[:script])
        .to eq({ inline: "ctx._source.title = 'hello'" })
    end

    # a Symbol before type cast means "copy from another column" - it must NOT be quoted
    it 'references another source field for a Symbol value' do
      attribute = query_attribute('title', :name, ActiveModel::Type::Value.new)

      expect(compile_assignment(attribute).body[:script])
        .to eq({ inline: 'ctx._source.title = ctx._source.name' })
    end
  end

  describe '#visit_Sort' do
    it 'assigns an ascending sort' do
      manager = Arel::SelectManager.new(table)
      manager.order(table['name'].asc)

      expect(visitor.compile(manager.ast).body).to eq({ sort: { 'name' => :asc } })
    end

    it 'assigns a descending sort' do
      manager = Arel::SelectManager.new(table)
      manager.order(table['name'].desc)

      expect(visitor.compile(manager.ast).body).to eq({ sort: { 'name' => :desc } })
    end

    # CAVEAT: each order node opens its OWN top-level +assign(:sort, {})+, and a top-level assign
    # REPLACES the key on the body instead of merging into it. So a multi-column order silently
    # keeps the LAST sort only - pinned here as the current behaviour, not as a desired one.
    # see @ Arel::Visitors::ElasticsearchBase#assign
    it 'keeps only the last sort for a multi-column order' do
      manager = Arel::SelectManager.new(table)
      manager.order(table['name'].asc)
      manager.order(table['count'].desc)

      expect(visitor.compile(manager.ast).body).to eq({ sort: { 'count' => :desc } })
    end

    # the special '__rand__' key builds a script-based random order
    it 'builds a random script sort for the __rand__ key' do
      manager = Arel::SelectManager.new(table)
      manager.order(Arel::Nodes::Ascending.new(Arel::Nodes::SqlLiteral.new('__rand__')))

      expect(visitor.compile(manager.ast).body).to eq({
                                                        sort: {
                                                          '_script' => {
                                                            'script' => 'Math.random()',
                                                            'type'   => 'number',
                                                            'order'  => :asc
                                                          }
                                                        }
                                                      })
    end
  end

  describe '#visit_Arel_Nodes_Limit / #visit_Arel_Nodes_Offset' do
    it 'assigns the limit as size' do
      manager = Arel::SelectManager.new(table)
      manager.take(25)

      expect(visitor.compile(manager.ast).body).to eq({ size: 25 })
    end

    it 'assigns the offset as from' do
      manager = Arel::SelectManager.new(table)
      manager.skip(50)

      expect(visitor.compile(manager.ast).body).to eq({ from: 50 })
    end
  end

  ######################
  # PREDICATE ASSIGNS  #
  ######################

  describe '#visit_Arel_Nodes_Equality' do
    def compile_where(node)
      manager = Arel::SelectManager.new(table)
      manager.where(node)

      visitor.compile(manager.ast)
    end

    it 'builds a term filter' do
      query = compile_where(Arel::Nodes::Equality.new(table['name'], query_attribute('name', 'x')))

      expect(query.body).to eq({ query: { bool: { filter: [{ term: { 'name' => 'x' } }] } } })
    end

    it 'appends multiple equalities into the same filter Array' do
      manager = Arel::SelectManager.new(table)
      manager.where(Arel::Nodes::Equality.new(table['name'], query_attribute('name', 'x')))
      manager.where(Arel::Nodes::Equality.new(table['title'], query_attribute('title', 'y')))

      expect(visitor.compile(manager.ast).body).to eq({
                                                        query: {
                                                          bool: {
                                                            filter: [
                                                              { term: { 'name' => 'x' } },
                                                              { term: { 'title' => 'y' } }
                                                            ]
                                                          }
                                                        }
                                                      })
    end

    # Elasticsearch has no NULL - a nil comparison becomes a "field does not exist" check
    it 'transforms a nil value into a must_not exists' do
      query = compile_where(Arel::Nodes::Equality.new(table['name'], query_attribute('name', nil)))

      expect(query.body).to eq({ query: { bool: { must_not: [{ exists: { field: 'name' } }] } } })
    end

    it 'fails the query for an invalid ("1=0") value' do
      query = compile_where(Arel::Nodes::Equality.new(table['name'], Arel::Nodes::SqlLiteral.new('1=0')))

      expect(query.status).to eq(ElasticsearchRecord::Query::STATUS_FAILED)
    end
  end

  describe '#visit_Arel_Nodes_NotEqual' do
    def compile_where(node)
      manager = Arel::SelectManager.new(table)
      manager.where(node)

      visitor.compile(manager.ast)
    end

    it 'builds a must_not term' do
      query = compile_where(Arel::Nodes::NotEqual.new(table['name'], query_attribute('name', 'x')))

      expect(query.body).to eq({ query: { bool: { must_not: [{ term: { 'name' => 'x' } }] } } })
    end

    # inverted counterpart of the Equality nil handling
    it 'transforms a nil value into an exists filter' do
      query = compile_where(Arel::Nodes::NotEqual.new(table['name'], query_attribute('name', nil)))

      expect(query.body).to eq({ query: { bool: { filter: [{ exists: { field: 'name' } }] } } })
    end

    it 'fails the query for an invalid ("1=0") value' do
      query = compile_where(Arel::Nodes::NotEqual.new(table['name'], Arel::Nodes::SqlLiteral.new('1=0')))

      expect(query.status).to eq(ElasticsearchRecord::Query::STATUS_FAILED)
    end
  end

  describe '#visit_Arel_Nodes_Grouping' do
    # grouping (SQL parentheses) has no Elasticsearch equivalent - rather than build a wrong query
    # the whole query is failed
    it 'fails the query' do
      manager = Arel::SelectManager.new(table)
      manager.where(Arel::Nodes::Grouping.new(
                      Arel::Nodes::Equality.new(table['name'], query_attribute('name', 'x'))
                    ))

      query = visitor.compile(manager.ast)

      expect(query.status).to eq(ElasticsearchRecord::Query::STATUS_FAILED)
      expect(query.body).to eq(ElasticsearchRecord::Query::FAILED_BODIES[ElasticsearchRecord::Query::TYPE_SEARCH])
    end
  end

  describe '#visit_Arel_Nodes_HomogeneousIn' do
    # rails 7.1 removed +column_name+ from the node - the field name now resolves
    # via +#left+ (the attribute), which the visitor renders to its name.
    let(:typed_table) do
      type_caster = Class.new do
        def type_for_attribute(_name)
          ActiveModel::Type::String.new
        end
      end.new

      Arel::Table.new('searches', type_caster: type_caster)
    end

    it 'builds a terms filter from the attribute name' do
      sm = Arel::SelectManager.new(typed_table)
      sm.where(Arel::Nodes::HomogeneousIn.new(%w[A00 B01], typed_table['code'], :in))

      query = visitor.compile(sm.ast)

      expect(query.body).to eq({ query: { bool: { filter: [{ terms: { 'code' => %w[A00 B01] } }] } } })
    end

    it 'builds a must_not terms filter for a :notin node' do
      sm = Arel::SelectManager.new(typed_table)
      sm.where(Arel::Nodes::HomogeneousIn.new(%w[A00 B01], typed_table['code'], :notin))

      query = visitor.compile(sm.ast)

      expect(query.body).to eq({ query: { bool: { must_not: [{ terms: { 'code' => %w[A00 B01] } }] } } })
    end

    # the values are assigned DIRECTLY (a nested Hash cannot carry binds), but the binds are still
    # forwarded so the statement cache on the other side keeps working
    # see @ ActiveRecord::StatementCache::PartialQueryCollector
    it 'marks the collector as not preparable & still adds the binds' do
      collector = Arel::Collectors::ElasticsearchQuery.new

      sm = Arel::SelectManager.new(typed_table)
      sm.where(Arel::Nodes::HomogeneousIn.new(%w[A00 B01], typed_table['code'], :in))
      visitor.compile(sm.ast, collector)

      expect(collector.preparable).to be(false)
      expect(collector.bind_index).to eq(3)
    end
  end

  describe '#visit_Arel_Nodes_In' do
    def compile_in(values)
      manager = Arel::SelectManager.new(table)
      manager.where(Arel::Nodes::In.new(table['name'], values))

      visitor.compile(manager.ast)
    end

    it 'builds a terms filter' do
      query = compile_in([query_attribute('name', 'a'), query_attribute('name', 'b')])

      expect(query.body).to eq({ query: { bool: { filter: [{ terms: { 'name' => %w[a b] } }] } } })
    end

    it 'fails the query for an empty Array' do
      expect(compile_in([]).status).to eq(ElasticsearchRecord::Query::STATUS_FAILED)
    end

    # an out-of-range value can never match - dropping it would silently widen the query
    it 'fails the query when every value is unboundable' do
      unboundable = query_attribute('count', 2**70, ActiveModel::Type::Integer.new)

      expect(compile_in([unboundable]).status).to eq(ElasticsearchRecord::Query::STATUS_FAILED)
    end

    it 'marks the collector as not preparable' do
      collector = Arel::Collectors::ElasticsearchQuery.new

      manager = Arel::SelectManager.new(table)
      manager.where(Arel::Nodes::In.new(table['name'], [query_attribute('name', 'a')]))
      visitor.compile(manager.ast, collector)

      expect(collector.preparable).to be(false)
    end
  end

  describe '#visit_Arel_Nodes_And' do
    it 'resolves every child independently' do
      manager = Arel::SelectManager.new(table)
      manager.where(Arel::Nodes::And.new([
                                           Arel::Nodes::Equality.new(table['a'], query_attribute('a', '1')),
                                           Arel::Nodes::NotEqual.new(table['b'], query_attribute('b', '2'))
                                         ]))

      expect(visitor.compile(manager.ast).body).to eq({
                                                        query: {
                                                          bool: {
                                                            filter:   [{ term: { 'a' => '1' } }],
                                                            must_not: [{ term: { 'b' => '2' } }]
                                                          }
                                                        }
                                                      })
    end
  end

  describe '#visit_Arel_Nodes_Or' do
    # +minimum_should_match+ is what makes the OR restrict at all: Elasticsearch only defaults it
    # to 1 while the +bool+ carries no +must+/+filter+ - and this one always sits inside a +filter+.
    it 'resolves each side into a nested bool and requires one of them to match' do
      manager = Arel::SelectManager.new(table)
      manager.where(Arel::Nodes::Grouping.new(Arel::Nodes::Or.new(
                                                Arel::Nodes::Equality.new(table['a'], query_attribute('a', '1')),
                                                Arel::Nodes::Equality.new(table['b'], query_attribute('b', '2'))
                                              )))

      expect(visitor.compile(manager.ast).body).to eq({
                                                        query: {
                                                          bool: {
                                                            filter: [{
                                                                       bool: {
                                                                         should:               [
                                                                           { bool: { filter: [{ term: { 'a' => '1' } }] } },
                                                                           { bool: { filter: [{ term: { 'b' => '2' } }] } }
                                                                         ],
                                                                         minimum_should_match: 1
                                                                       }
                                                                     }]
                                                          }
                                                        }
                                                      })
    end

    it 'flattens a chained Or into sibling should clauses' do
      manager = Arel::SelectManager.new(table)
      manager.where(Arel::Nodes::Grouping.new(Arel::Nodes::Or.new(
                                                Arel::Nodes::Or.new(
                                                  Arel::Nodes::Equality.new(table['a'], query_attribute('a', '1')),
                                                  Arel::Nodes::Equality.new(table['b'], query_attribute('b', '2'))
                                                ),
                                                Arel::Nodes::Equality.new(table['c'], query_attribute('c', '3'))
                                              )))

      should = visitor.compile(manager.ast).body[:query][:bool][:filter][0][:bool][:should]

      expect(should.length).to eq(3)
    end
  end

  #########################
  # SOURCE / TABLE VISITS #
  #########################

  describe '#visit_Arel_Nodes_JoinSource' do
    it 'claims the index from the left side' do
      expect(visitor.compile(Arel::SelectManager.new(table).ast).index).to eq('bar')
    end

    it 'raises for any join' do
      manager = Arel::SelectManager.new(table)
      manager.join(Arel::Table.new('other')).on(Arel::Nodes::Equality.new(table['a'], query_attribute('a', '1')))

      expect { visitor.compile(manager.ast) }
        .to raise_error(ActiveRecord::StatementInvalid, /table joins are not supported/)
    end
  end

  describe '#visit_Arel_Table' do
    it 'claims the table name as index' do
      query = visitor.compile(Arel::SelectManager.new(Arel::Table.new('my-index')).ast)

      expect(query.index).to eq('my-index')
    end

    it 'raises for an aliased table' do
      expect { visitor.send(:visit, Arel::Table.new('bar', as: 'b')) }
        .to raise_error(ActiveRecord::StatementInvalid, /table alias are not supported \(b\)/)
    end
  end

  ################
  # LEAF VISITS  #
  ################

  # these only convert a value - they never claim or assign
  describe 'raw visits' do
    {
      'an Integer'    => 42,
      'a Symbol'      => :sym,
      'a Hash'        => { a: 1 },
      'a nil'         => nil,
      'a String'      => 'str'
    }.each do |label, value|
      it "returns #{label} unchanged" do
        expect(visitor.send(:visit, value)).to eq(value)
      end
    end

    it 'returns a SqlLiteral unchanged' do
      expect(visitor.send(:visit, Arel::Nodes::SqlLiteral.new('raw'))).to eq('raw')
    end

    it 'collects an Array element-wise' do
      expect(visitor.send(:visit, [1, :a, 'x'])).to eq([1, :a, 'x'])
    end
  end

  describe 'attribute visits' do
    it 'returns the NAME of an Arel attribute' do
      expect(visitor.send(:visit, table['name'])).to eq('name')
    end

    it 'returns the NAME of an unqualified column' do
      expect(visitor.send(:visit, Arel::Nodes::UnqualifiedColumn.new(table['name']))).to eq('name')
    end

    # PLEASE NOTE: a "from user" attribute resolves to its NAME - not its value
    # see @ the insert regression specs above
    it 'returns the NAME of an ActiveModel::Attribute::FromUser' do
      attribute = ActiveModel::Attribute.from_user('n', 'val', ActiveModel::Type::String.new)

      expect(visitor.send(:visit, attribute)).to eq('n')
    end

    it 'returns the VALUE of an ActiveModel::Attribute::WithCastValue' do
      attribute = ActiveModel::Attribute.with_cast_value('n', 'val', ActiveModel::Type::String.new)

      expect(visitor.send(:visit, attribute)).to eq('val')
    end
  end

  describe 'bind visits' do
    it 'returns the value & registers a bind on the collector' do
      collector        = Arel::Collectors::ElasticsearchQuery.new
      visitor.collector = collector

      value = visitor.send(:visit, query_attribute('name', 'x'))

      expect(value).to eq('x')
      expect(collector.bind_index).to eq(2)
    end
  end

  describe '#visit_Arel_Nodes_ValuesList' do
    # does not claim anything - it only builds the "name => value" Hash for insert / update
    it 'reduces the rows into a single Hash' do
      im        = Arel::InsertManager.new(table)
      im.values = Arel::Nodes::ValuesList.new([[query_attribute('a', 1), query_attribute('b', 2)]])

      expect(visitor.compile(im.ast).body).to eq({ 'a' => 1, 'b' => 2 })
    end
  end

  describe 'data type visits' do
    it 'returns true for a True node' do
      expect(visitor.send(:visit, Arel::Nodes::True.new)).to be(true)
    end

    it 'returns false for a False node' do
      expect(visitor.send(:visit, Arel::Nodes::False.new)).to be(false)
    end
  end

  # unsupported nodes must fail LOUDLY - a silently dropped node would produce a wrong query.
  # The fix for such a failure is to construct a custom Arel node, never to add SQL-ish handling.
  describe 'unsupported nodes' do
    it 'raises an UnsupportedVisitError' do
      manager = Arel::SelectManager.new(table)
      # +Arel::Nodes::Casted+ is what a plain +table['a'].eq(1)+ produces - the gem always goes
      # through the predicate builder (QueryAttribute) instead
      manager.where(table['a'].eq(1))

      expect { visitor.compile(manager.ast) }
        .to raise_error(Arel::Visitors::ElasticsearchBase::UnsupportedVisitError, /visit_Arel_Nodes_Casted/)
    end

    # a grouping that does NOT wrap an Or has no Elasticsearch equivalent and still fails the query
    it 'fails the query for a grouping of anything but an Or' do
      manager = Arel::SelectManager.new(table)
      manager.where(Arel::Nodes::Grouping.new(
                      Arel::Nodes::Equality.new(table['a'], query_attribute('a', '1'))
                    ))

      expect(visitor.compile(manager.ast).status).to eq(ElasticsearchRecord::Query::STATUS_FAILED)
    end

    # +method_missing+ only guards +visit_*+ - everything else keeps the regular NoMethodError
    it 'does not swallow other missing methods' do
      expect { visitor.send(:nope) }.to raise_error(NoMethodError)
    end
  end

  # a build-time exception must not leak the nested-assign state into the NEXT compile
  # see @ Arel::Visitors::ElasticsearchBase#compile (fixed in 1.8.2)
  describe 'state isolation between compiles' do
    it 'resets the nested state after a failed compile' do
      broken = Arel::SelectManager.new(table)
      broken.where(table['a'].eq(1))

      expect { visitor.compile(broken.ast) }.to raise_error(Arel::Visitors::ElasticsearchBase::UnsupportedVisitError)

      manager = Arel::SelectManager.new(table)
      manager.where(Arel::Nodes::Equality.new(table['name'], query_attribute('name', 'x')))

      expect(visitor.compile(manager.ast).body)
        .to eq({ query: { bool: { filter: [{ term: { 'name' => 'x' } }] } } })
    end
  end
end
