# frozen_string_literal: true

# Covers the behaviour that was added / corrected for Elasticsearch 8.19.
#
# Everything here is either a REGRESSION guard for a bug that produced silently wrong results, or a
# feature that only exists from 8.12 onwards. The range predicates have their own file
# (see @ spec/elasticsearch_record/relation/range_predicates_spec.rb).
RSpec.describe 'Elasticsearch 8.19 compatibility', :elasticsearch do
  before do
    TestIndex.create!

    model.create!(name: 'alpha', count: 1, active: true)
    model.create!(name: 'beta',  count: 3, active: false)
    model.create!(name: 'gamma', count: 5, active: true)
    model.api.refresh!
  end

  after { TestIndex.drop! }

  subject(:model) do
    Class.new(ElasticsearchRecord::Base) {
      def self.name = 'Es819SpecModel'
    }.tap { |klass|
      klass.table_name = TestIndex.name
      klass.reset_column_information
    }
  end

  # -------------------------------------------------------------------------------------------
  # +.or+ used to compile into the match-nothing +FAILED_BODIES+ body, because ActiveRecord wraps
  # the OR into a +Grouping+ and the visitor failed EVERY grouping. It returned zero records
  # without raising - the worst possible failure mode.
  describe '#or' do
    it 'resolves the union of both sides' do
      relation = model.where(name: 'alpha').or(model.where(name: 'gamma'))

      expect(relation.pluck(:name)).to match_array(%w[alpha gamma])
    end

    it 'keeps a common condition restricting' do
      # the common 'active' clause is factored OUT of the Or by ActiveRecord, so it ends up as a
      # sibling +filter+ of the +should+ - which is exactly the case that needs
      # +minimum_should_match+, since elasticsearch defaults it to 0 as soon as a filter exists
      relation = model.where(active: true).where(name: 'alpha')
                      .or(model.where(active: true).where(name: 'beta'))

      expect(relation.pluck(:name)).to eq(%w[alpha])
    end

    it 'resolves the union of a query clause OR' do
      relation = model.filter({ term: { name: 'alpha' } }).or(model.filter({ term: { name: 'beta' } }))

      expect(relation.pluck(:name)).to match_array(%w[alpha beta])
    end
  end

  # -------------------------------------------------------------------------------------------
  describe '#total' do
    it 'reports an exact total as exact' do
      expect(model.all.total).to eq(3)
      expect(model.all.total_relation).to eq('eq')
      expect(model.all.total_exact?).to be(true)
    end

    # REGRESSION: 'hits.total' is absent entirely for this query - the former
    # response['hits']['total']['value'] raised a NoMethodError on nil
    it 'does not raise when the total was not tracked' do
      expect(model.all.configure(track_total_hits: false).total).to be_nil
    end
  end

  describe ElasticsearchRecord::Result do
    it 'reports a capped total as a lower bound' do
      result = described_class.new({ 'hits' => { 'total' => { 'value' => 10_000, 'relation' => 'gte' },
                                                 'hits'  => [] } })

      expect(result.total).to eq(10_000)
      expect(result.total_relation).to eq('gte')
      expect(result.total_exact?).to be(false)
    end

    # 'rest_total_hits_as_int' answers with a plain Integer instead of the {value:, relation:} Hash
    it 'resolves an integer total' do
      result = described_class.new({ 'hits' => { 'total' => 42, 'hits' => [] } })

      expect(result.total).to eq(42)
      expect(result.total_relation).to be_nil
    end

    it 'reports a partial result' do
      expect(described_class.new({ 'is_partial' => true }).is_partial?).to be(true)
      expect(described_class.new({ 'is_partial' => false }).is_partial?).to be(false)
      expect(described_class.new({}).is_partial?).to be(false)
    end
  end

  # -------------------------------------------------------------------------------------------
  describe 'ES|QL' do
    it 'reports the 8.19 response fields' do
      result = model.esql("FROM #{TestIndex.name} | KEEP name | LIMIT 3")

      expect(result.is_partial?).to be(false)
      expect(result.documents_found).to be_a(Integer)
      expect(result.values_loaded).to be_a(Integer)
    end

    it 'raises for a partial result while error_on_partial_results is enabled' do
      begin
        ElasticsearchRecord.error_on_partial_results = true

        allow(model.connection).to receive(:api).and_call_original
        # a partial response is only produced by an actually unavailable shard - faking the flag is
        # the only way to reach the guard deterministically
        allow_any_instance_of(Elasticsearch::API::Response).to receive(:[]) do |resp, key|
          key == 'is_partial' ? true : resp.body[key]
        end

        expect { model.esql("FROM #{TestIndex.name} | LIMIT 1") }
          .to raise_error(ActiveRecord::StatementInvalid, /PARTIAL results/)
      ensure
        ElasticsearchRecord.error_on_partial_results = false
      end
    end
  end

  # -------------------------------------------------------------------------------------------
  describe 'deprecation warnings' do
    # 8.19 answers a legacy range query with a 'Warning' header. The values still resolve
    # correctly, but the syntax is scheduled for removal - which is exactly what has to become
    # visible before a major upgrade.
    it 'collects the Warning header of a deprecated query' do
      captured = nil

      ActiveSupport::Notifications.subscribed(->(*, payload) {
        captured ||= payload[:statistics][:warnings] if payload[:statistics].is_a?(Hash)
      }, 'query.elasticsearch_record') do
        model.filter(range: { count: { from: 1, to: 5, include_lower: true, include_upper: true } }).to_a
      end

      expect(captured).to include(a_string_matching(/Deprecated field \[from\] used/))
    end

    it 'reports no warnings for a modern range query' do
      captured = :unset

      ActiveSupport::Notifications.subscribed(->(*, payload) {
        captured = payload[:statistics][:warnings] if payload[:statistics].is_a?(Hash)
      }, 'query.elasticsearch_record') do
        model.where(count: 1..5).to_a
      end

      expect(captured).to be_nil
    end
  end

  # -------------------------------------------------------------------------------------------
  describe '#knn' do
    it 'assigns the knn node next to the query' do
      relation = model.where(active: true).knn(field: :embedding, query_vector: [0.1], k: 5)

      expect(relation.to_query[:body][:knn]).to eq({ field: :embedding, query_vector: [0.1], k: 5 })
      expect(relation.to_query[:body][:query]).to be_present
    end
  end

  describe '#restrict' do
    it 'excludes a field from the transferred _source' do
      expect(model.all.restrict(excludes: :count).results.first.keys).not_to include('count')
      expect(model.all.results.first.keys).to include('count')
    end

    it 'includes only the provided fields' do
      expect(model.all.restrict(includes: :name).results.first.keys).to eq(%w[name])
    end

    it 'builds the 8.19 exclude_vectors flag' do
      expect(model.all.restrict(exclude_vectors: true).to_query[:body][:_source])
        .to eq({ exclude_vectors: true })
    end

    it 'raises without any argument' do
      expect { model.all.restrict }.to raise_error(ArgumentError, /at least one of/)
    end
  end

  # -------------------------------------------------------------------------------------------
  describe 'index name validation' do
    it 'raises for an invalid index name instead of sending it' do
      expect { model.connection.create_table('Elasticsearch_Record_Test_UPPER', decorate: false) }
        .to raise_error(ArgumentError, /must be lowercase/)
    end

    it 'raises for a dot-prefixed (internal) index name' do
      expect { model.connection.create_table('.elasticsearch_record_test', decorate: false) }
        .to raise_error(ArgumentError, /reserved for internal indices/)
    end
  end

  # -------------------------------------------------------------------------------------------
  # REGRESSION: +transform_mappings!+ only read '_meta' and 'properties', so every other node of
  # the mapping root was dropped. Since +truncate_table+ RECREATES the index from that definition,
  # a truncate silently destroyed e.g. the dynamic_templates of an index.
  describe 'mapping round-trip' do
    let(:index_name) { "#{ElasticsearchSpec::TEST_INDEX}_roundtrip" }

    before do
      TestIndex.drop!(index_name)

      model.connection.api('indices.create', {
        index: index_name,
        body:  {
          mappings: {
            dynamic:           'strict',
            date_detection:    false,
            dynamic_templates: [{ strings: { match_mapping_type: 'string', mapping: { type: 'keyword' } } }],
            runtime:           { day_of_week: { type: 'keyword' } },
            _source:           { excludes: ['secret'] },
            properties:        { name: { type: 'keyword' }, secret: { type: 'keyword' } }
          },
          settings: { number_of_shards: 1, number_of_replicas: 0 }
        }
      }, 'SPEC SETUP')
    end

    after { TestIndex.drop!(index_name) }

    it 'keeps every mapping-root node when recreating from the resolved schema' do
      before_mappings = model.connection.table_mappings(index_name)
      schema          = model.connection.table_schema(index_name)

      model.connection.create_table(index_name, force: true, decorate: false, **schema)

      expect(model.connection.table_mappings(index_name)).to eq(before_mappings)
    end

    it 'keeps them through a truncate' do
      before_mappings = model.connection.table_mappings(index_name)

      model.connection.truncate_table(index_name, decorate: false)

      expect(model.connection.table_mappings(index_name)).to eq(before_mappings)
    end
  end
end
