# frozen_string_literal: true

# Covers every public method of +ElasticsearchRecord::Relation::ResultMethods+.
#
# These methods bypass the ActiveRecord record-instantiation and resolve RAW parts of the
# Elasticsearch response (hits / aggregations / buckets / total) or run batched
# +point_in_time+ based queries.
#
# see @ ElasticsearchRecord::Relation::ResultMethods
RSpec.describe ElasticsearchRecord::Relation::ResultMethods, :elasticsearch do
  # PLEASE NOTE: the +:elasticsearch+ tag skips these examples through a +before(:each)+ hook
  # (see spec_helper.rb) - so the index setup must NOT run in a +before(:all)+, which would
  # execute before that hook and blow up instead of skipping.
  before do
    TestIndex.create!

    model.create!(name: 'alpha', count: 1, active: true)
    model.create!(name: 'beta', count: 2, active: false)
    model.create!(name: 'beta', count: 3, active: true)
    model.create!(name: 'gamma', count: 4, active: true)
    model.api.refresh!
  end

  after { TestIndex.drop! }

  subject(:model) do
    Class.new(ElasticsearchRecord::Base) {
      def self.name = 'ResultMethodsSpecModel'
    }.tap { |klass|
      klass.table_name = TestIndex.name
      klass.reset_column_information
    }
  end

  describe '#agg_pluck' do
    it 'resolves the values of a single column' do
      expect(model.all.agg_pluck(:name)).to eq({ 'name' => %w[beta alpha gamma] })
    end

    it 'resolves the values of multiple columns' do
      result = model.all.agg_pluck(:name, :count)

      expect(result.keys).to match_array(%w[name count])
      expect(result['name']).to match_array(%w[alpha beta gamma])
      expect(result['count']).to match_array([1, 2, 3, 4])
    end

    it 'returns String keys - even for provided Symbols' do
      expect(model.all.agg_pluck(:name).keys).to eq(['name'])
      expect(model.all.agg_pluck('name').keys).to eq(['name'])
    end

    it 'resolves distinct values only' do
      # 'beta' exists twice, but the terms-aggregation buckets it once
      expect(model.all.agg_pluck(:name)['name'].size).to eq(3)
    end

    it 'respects a provided limit as the terms size' do
      expect(model.limit(1).agg_pluck(:name)['name'].size).to eq(1)
      expect(model.limit(2).agg_pluck(:name)['name'].size).to eq(2)
    end

    it 'respects the current relation scope' do
      expect(model.where(active: true).agg_pluck(:name)['name']).to match_array(%w[alpha beta gamma])
      expect(model.where(active: false).agg_pluck(:name)['name']).to eq(['beta'])
    end

    it 'returns an empty hash without any provided column' do
      expect(model.all.agg_pluck).to eq({})
    end

    it 'does not modify the current relation' do
      relation = model.all

      relation.agg_pluck(:name)

      expect(relation.aggs_clause).to be_blank
    end
  end

  describe '#composite' do
    it 'resolves a single column as key => doc_count' do
      expect(model.all.composite(:name)).to eq({ 'alpha' => 1, 'beta' => 2, 'gamma' => 1 })
    end

    it 'resolves multiple columns as a key-hash => doc_count' do
      result = model.all.composite(:name, :active)

      expect(result).to eq({
                             { 'name' => 'alpha', 'active' => true } => 1,
                             { 'name' => 'beta', 'active' => false } => 1,
                             { 'name' => 'beta', 'active' => true }  => 1,
                             { 'name' => 'gamma', 'active' => true } => 1
                           })
    end

    it 'respects a provided limit as the composite size' do
      expect(model.limit(2).composite(:name).size).to eq(2)
    end

    it 'respects the current relation scope' do
      expect(model.where(active: false).composite(:name)).to eq({ 'beta' => 1 })
    end

    it 'does not modify the current relation' do
      relation = model.all

      relation.composite(:name)

      expect(relation.aggs_clause).to be_blank
    end
  end

  describe '#point_in_time' do
    it 'returns a new pit id without a provided block' do
      pit_id = model.all.point_in_time

      expect(pit_id).to be_a(String).and be_present

      # cleanup - the pit is only auto-closed when a block was provided
      model.connection.api(:close_point_in_time, { body: { id: pit_id } }, 'Close Pit')
    end

    it 'yields the pit id and returns nil with a provided block' do
      yielded = nil

      expect(model.all.point_in_time { |pit_id| yielded = pit_id }).to be_nil
      expect(yielded).to be_a(String).and be_present
    end

    it 'closes the pit after the block was yielded' do
      yielded = nil

      model.all.point_in_time { |pit_id| yielded = pit_id }

      # a closed pit cannot be reused
      expect {
        model.connection.api(:search, { body: { pit: { id: yielded, keep_alive: '1m' } } }, 'Search Pit')
      }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it 'forwards the provided keep_alive' do
      allow(model.connection).to receive(:api).and_call_original

      expect(model.connection).to receive(:api)
        .with(:open_point_in_time, hash_including(keep_alive: '5m'), anything)
        .and_call_original

      pit_id = model.all.point_in_time(keep_alive: '5m')

      model.connection.api(:close_point_in_time, { body: { id: pit_id } }, 'Close Pit')
    end

    it 'is aliased as #pit' do
      expect(described_class.instance_method(:pit).original_name).to eq(:point_in_time)
    end
  end

  describe '#pit_results' do
    it 'resolves all results' do
      results = model.all.pit_results

      expect(results.size).to eq(4)
      expect(results.map { |result| result['name'] }).to match_array(%w[alpha beta beta gamma])
    end

    it 'merges the _id into each result' do
      expect(model.all.pit_results.map { |result| result['_id'] }).to all(be_a(String).and(be_present))
    end

    # PLEASE NOTE: +meta_only!+ disables the +_source+ - so each result only contains the
    # metadata nodes of the hit ('_id', '_index', '_score', ...) and NOT a plain id-String.
    # see @ ElasticsearchRecord::Relation::ResultMethods#meta_only!
    it 'resolves only meta' do
      data = model.all.meta_only!.pit_results

      expect(data.size).to eq(4)
      expect(data).to all(be_a(Hash))
      expect(data.map(&:keys).flatten.uniq).to match_array(%w[_id _index _score])
      expect(data.map { |result| result['_id'] }).to match_array(model.all.ids)
    end

    it 'resolves batched results across multiple queries' do
      # batch_size 1 forces one query per document
      results = model.all.pit_results(batch_size: 1)

      expect(results.size).to eq(4)
      expect(results.map { |result| result['name'] }).to match_array(%w[alpha beta beta gamma])
    end

    it 'yields the results per batch and returns the total' do
      batches = []

      total = model.all.pit_results(batch_size: 3) { |batch| batches << batch }

      expect(total).to eq(4)
      expect(batches.map(&:size)).to eq([3, 1])
      expect(batches.flatten.map { |result| result['name'] }).to match_array(%w[alpha beta beta gamma])
    end

    # PLEASE NOTE: the loop only breaks AFTER a query returned less than +batch_size+ results -
    # so an evenly divisible result set yields a trailing EMPTY batch. Any provided block must
    # cope with that (see +#pit_delete+, which skips empty batches).
    it 'yields a trailing empty batch when the results are evenly divisible' do
      batches = []

      total = model.all.pit_results(batch_size: 2) { |batch| batches << batch }

      expect(total).to eq(4)
      expect(batches.map(&:size)).to eq([2, 2, 0])
    end

    it 'respects the current relation scope' do
      results = model.where(active: true).pit_results

      expect(results.size).to eq(3)
      expect(results.map { |result| result['name'] }).to match_array(%w[alpha beta gamma])
    end

    it 'respects a provided limit' do
      expect(model.limit(2).pit_results.size).to eq(2)
      expect(model.limit(3).pit_results(batch_size: 2).size).to eq(3)
    end

    it 'respects a provided offset' do
      ordered = model.order(count: :asc)

      expect(ordered.pit_results.map { |result| result['count'] }).to eq([1, 2, 3, 4])
      expect(ordered.offset(2).pit_results.map { |result| result['count'] }).to eq([3, 4])
    end

    it 'respects a provided offset across batches' do
      expect(
        model.order(count: :asc).offset(1).pit_results(batch_size: 2).map { |result| result['count'] }
      ).to eq([2, 3, 4])
    end

    it 'respects a combined limit & offset' do
      expect(
        model.order(count: :asc).offset(1).limit(2).pit_results.map { |result| result['count'] }
      ).to eq([2, 3])
    end

    it 'keeps a provided order' do
      expect(model.order(count: :desc).pit_results.map { |result| result['count'] }).to eq([4, 3, 2, 1])
    end

    it 'returns an empty array for a non-matching scope' do
      expect(model.where(name: 'nope').pit_results).to eq([])
    end

    it 'raises for a batch_size above the max_result_window' do
      expect {
        model.all.pit_results(batch_size: model.max_result_window + 1)
      }.to raise_error(ArgumentError, /Batch size cannot be above the 'max_result_window'/)
    end

    it 'closes the pit after resolving' do
      allow(model.connection).to receive(:api).and_call_original

      expect(model.connection).to receive(:api)
        .with(:close_point_in_time, anything, anything)
        .and_call_original

      model.all.pit_results
    end

    it 'does not modify the current relation' do
      relation = model.all

      relation.pit_results

      expect(relation).not_to be_loaded
      expect(relation.limit_value).to be_nil
      expect(relation.offset_value).to be_nil
    end

    it 'is aliased as #total_results' do
      expect(described_class.instance_method(:total_results).original_name).to eq(:pit_results)
    end
  end

  # PLEASE NOTE: +pit_delete+ resolves the '_id' of each doc through +meta_only!+ - it must NOT
  # +select('_id')+, since +QueryMethods#select+ raises for metadata fields (they are always
  # returned and therefore not resolvable through a projection).
  #
  # see @ ElasticsearchRecord::Relation::ResultMethods#pit_delete
  # see @ ElasticsearchRecord::Relation::QueryMethods#select
  describe '#pit_delete' do
    it 'deletes all docs of the current scope and returns the total count' do
      expect(model.all.pit_delete).to eq(4)
      expect(model.count).to eq(0)
    end

    it 'only deletes the docs of the current scope' do
      expect(model.where(active: false).pit_delete).to eq(1)

      expect(model.count).to eq(3)
      expect(model.pluck(:name)).to match_array(%w[alpha beta gamma])
    end

    it 'deletes in batches' do
      expect(model.all.pit_delete(batch_size: 1)).to eq(4)
      expect(model.count).to eq(0)
    end

    it 'respects a provided limit' do
      expect(model.order(count: :asc).limit(2).pit_delete).to eq(2)

      expect(model.pluck(:count)).to match_array([3, 4])
    end

    it 'returns 0 for a non-matching scope' do
      expect(model.where(name: 'nope').pit_delete).to eq(0)
      expect(model.count).to eq(4)
    end

    it 'refreshes the index by default' do
      expect(model.connection).to receive(:refresh_table).with(model.table_name).and_call_original

      model.all.pit_delete

      # without a refresh the count would still resolve the deleted docs
      expect(model.count).to eq(0)
    end

    it 'does not refresh the index when disabled' do
      allow(model.connection).to receive(:refresh_table).and_call_original

      expect(model.all.pit_delete(refresh: false)).to eq(4)
      expect(model.connection).not_to have_received(:refresh_table)
    end
  end

  describe '#response' do
    it 'returns the RAW response' do
      response = model.all.response

      # the RAW response is the +Elasticsearch::API::Response+ - NOT a plain Hash
      expect(response).to be_a(Elasticsearch::API::Response)
      expect(response['hits']['hits'].size).to eq(4)
      expect(response['hits']['total']['value']).to eq(4)
    end

    it 'drops the aggs from the query' do
      expect(model.aggregate(:total, { sum: { field: :count } }).response).not_to have_key('aggregations')
    end

    it 'respects the current relation scope' do
      expect(model.where(active: false).response['hits']['hits'].size).to eq(1)
    end

    it 'does not modify the current relation' do
      relation = model.aggregate(:total, { sum: { field: :count } })

      relation.response

      expect(relation.aggs_clause).to be_present
      expect(relation).not_to be_loaded
    end
  end

  describe '#aggregations' do
    it 'returns the RAW aggregations' do
      aggs = model.aggregate(:total, { sum: { field: :count } }).aggregations

      expect(aggs[:total][:value]).to eq(10)
    end

    it 'supports indifferent access' do
      aggs = model.aggregate(:total, { sum: { field: :count } }).aggregations

      expect(aggs['total']['value']).to eq(10)
    end

    it 'returns an empty hash without any aggregation' do
      expect(model.all.aggregations).to eq({})
    end

    it 'drops the hits from the query' do
      relation = model.aggregate(:total, { sum: { field: :count } })

      # +aggs_only!+ sets size:0 - so no hits are transferred
      expect(relation.spawn.aggs_only!.resolve('Aggregations').response['hits']['hits']).to eq([])
    end

    it 'respects the current relation scope' do
      aggs = model.where(active: true).aggregate(:total, { sum: { field: :count } }).aggregations

      expect(aggs[:total][:value]).to eq(8)
    end

    it 'does not modify the current relation' do
      relation = model.aggregate(:total, { sum: { field: :count } })

      relation.aggregations

      expect(relation).not_to be_loaded
      expect(relation.configure_value).to be_blank
    end
  end

  # PLEASE NOTE: +buckets+ resolves the bucket VALUES - not the +doc_count+.
  # +ElasticsearchRecord::Result#_resolve_bucket+ explicitly strips the bucket meta keys
  # ('key', 'doc_count', 'key_as_string', ...) and resolves the remaining sub-aggregations.
  # A terms-aggregation WITHOUT any sub-aggregation therefore resolves each key to +nil+.
  # Use +#composite+ (or +#aggregations+) when the +doc_count+ is what you need.
  # see @ ElasticsearchRecord::Result#_resolve_bucket
  describe '#buckets' do
    it 'resolves the bucket keys of a terms aggregation' do
      relation = model.aggregate(:names, { terms: { field: :name } })

      expect(relation.buckets[:names].keys).to match_array(%w[alpha beta gamma])
    end

    it 'resolves a bucket without any sub-aggregation as nil' do
      relation = model.aggregate(:names, { terms: { field: :name } })

      expect(relation.buckets[:names]).to eq({ 'beta' => nil, 'alpha' => nil, 'gamma' => nil })
    end

    it 'resolves the values of a sub-aggregation' do
      relation = model.aggregate(:names, {
        terms: { field: :name },
        aggs:  { total: { sum: { field: :count } } }
      })

      # 'beta' exists twice (count 2 & 3)
      expect(relation.buckets[:names]).to eq({
                                               'beta'  => { 'total' => 5 },
                                               'alpha' => { 'total' => 1 },
                                               'gamma' => { 'total' => 4 }
                                             })
    end

    it 'supports indifferent access' do
      relation = model.aggregate(:names, {
        terms: { field: :name },
        aggs:  { total: { sum: { field: :count } } }
      })

      expect(relation.buckets['names']['beta']['total']).to eq(5)
    end

    it 'resolves the value of a metric aggregation' do
      relation = model.aggregate(:total, { sum: { field: :count } })

      expect(relation.buckets).to eq({ 'total' => 10 })
    end

    it 'resolves multiple aggregations' do
      relation = model.aggregate(:names, { terms: { field: :name } })
                      .aggregate(:total, { sum: { field: :count } })

      expect(relation.buckets.keys).to match_array(%w[names total])
      expect(relation.buckets[:total]).to eq(10)
    end

    it 'returns an empty hash without any aggregation' do
      expect(model.all.buckets).to eq({})
    end

    it 'respects the current relation scope' do
      relation = model.where(active: true).aggregate(:names, { terms: { field: :name } })

      expect(relation.buckets[:names].keys).to match_array(%w[alpha beta gamma])
    end
  end

  describe '#hits' do
    it 'returns the RAW hits hash' do
      hits = model.all.hits

      expect(hits[:total][:value]).to eq(4)
      expect(hits[:hits].size).to eq(4)
    end

    it 'supports indifferent access' do
      expect(model.all.hits['total']['value']).to eq(4)
    end

    it 'contains the metadata of each hit' do
      hit = model.all.hits[:hits].first

      expect(hit[:_id]).to be_present
      expect(hit[:_index]).to eq(TestIndex.name)
      expect(hit[:_source]).to be_a(Hash)
    end

    it 'respects the current relation scope' do
      expect(model.where(active: false).hits[:hits].size).to eq(1)
    end

    it 'does not modify the current relation' do
      relation = model.all

      relation.hits

      expect(relation).not_to be_loaded
    end
  end

  describe '#results' do
    it 'returns the RAW _source of each hit' do
      results = model.all.results

      expect(results.size).to eq(4)
      expect(results.map { |result| result['name'] }).to match_array(%w[alpha beta beta gamma])
    end

    it 'does not contain any metadata' do
      keys = model.all.results.map(&:keys).flatten.uniq

      expect(keys).to match_array(%w[name count active created_at])
      expect(keys).not_to include('_id', '_index', '_score')
    end

    it 'respects the current relation scope' do
      expect(model.where(active: false).results.map { |result| result['name'] }).to eq(['beta'])
    end

    it 'returns an empty array for a non-matching scope' do
      expect(model.where(name: 'nope').results).to eq([])
    end

    it 'does not instantiate any record' do
      expect(model.all.results).to all(be_a(Hash))
    end
  end

  describe '#total' do
    it 'returns the total value' do
      expect(model.all.total).to eq(4)
    end

    it 'respects the current relation scope' do
      expect(model.where(active: true).total).to eq(3)
      expect(model.where(name: 'nope').total).to eq(0)
    end

    it 'ignores a provided limit' do
      # the total is the amount of matching docs - not the amount of returned hits
      expect(model.limit(1).total).to eq(4)
    end

    it 'resolves the total from an already loaded relation' do
      relation = model.all
      relation.load

      # a loaded relation must not send another query
      expect(model.connection).not_to receive(:select_all)
      expect(relation.total).to eq(4)
    end

    it 'resolves the total from a loaded & limited relation' do
      relation = model.limit(1)
      relation.load

      expect(relation.size).to eq(1)
      expect(relation.total).to eq(4)
    end

    it 'does not modify the current relation' do
      relation = model.all

      relation.total

      expect(relation).not_to be_loaded
    end
  end

  describe '#hits_only!' do
    it 'drops the aggs from the query' do
      relation = model.aggregate(:total, { sum: { field: :count } }).hits_only!

      # dropping the only body-node leaves no +body+ at all
      expect(relation.to_query[:body].to_h).not_to have_key(:aggs)
    end

    it 'keeps the hits within the query' do
      # +hits_only!+ must not restrict the size / _source - otherwise no hits would return
      expect(model.all.hits_only!.to_query[:body].to_h).not_to have_key(:size)
      expect(model.all.hits_only!.resolve('Hits').response['hits']['hits'].size).to eq(4)
    end

    it 'returns itself for chaining' do
      relation = model.all

      expect(relation.hits_only!).to equal(relation)
    end
  end

  describe '#aggs_only!' do
    it 'drops the hits related options from the query' do
      body = model.order(count: :asc).aggregate(:total, { sum: { field: :count } }).aggs_only!.to_query[:body]

      expect(body[:size]).to eq(0)
      expect(body[:_source]).to eq(false)
      expect(body).not_to have_key(:from)
      expect(body).not_to have_key(:sort)
    end

    it 'keeps the aggs within the query' do
      body = model.aggregate(:total, { sum: { field: :count } }).aggs_only!.to_query[:body]

      expect(body[:aggs]).to eq({ total: { sum: { field: :count } } })
    end

    it 'returns no hits' do
      relation = model.all.aggs_only!

      expect(relation.resolve('Aggs').response['hits']['hits']).to eq([])
    end

    it 'returns itself for chaining' do
      relation = model.all

      expect(relation.aggs_only!).to equal(relation)
    end
  end

  describe '#total_only!' do
    it 'drops the hits & aggs related options from the query' do
      body = model.order(count: :asc).aggregate(:total, { sum: { field: :count } }).total_only!.to_query[:body]

      expect(body[:size]).to eq(0)
      expect(body[:_source]).to eq(false)
      expect(body).not_to have_key(:from)
      expect(body).not_to have_key(:sort)
      expect(body).not_to have_key(:aggs)
    end

    it 'returns neither hits nor aggs' do
      response = model.aggregate(:total, { sum: { field: :count } }).total_only!.resolve('Total').response

      expect(response['hits']['hits']).to eq([])
      expect(response).not_to have_key('aggregations')
    end

    it 'still resolves the total' do
      expect(model.all.total_only!.resolve('Total').total).to eq(4)
    end

    it 'returns itself for chaining' do
      relation = model.all

      expect(relation.total_only!).to equal(relation)
    end
  end
end
