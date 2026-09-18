# frozen_string_literal: true

# Covers how the gem resolves its connection - and the schema values it caches on the model.
#
# Since rails 7.2 +Model.connection+ is SOFT DEPRECATED: it leases a connection to the current
# thread PERMANENTLY. An application can turn that into a warning or an error through
# +ActiveRecord.permanent_connection_checkout+ (+:deprecated+ / +:disallowed+) - so the gem itself
# must only ever resolve its connection through +with_connection+.
#
# see @ ActiveRecord::ConnectionHandling#connection
RSpec.describe 'ElasticsearchRecord connection handling', :elasticsearch do
  before do
    TestIndex.create!

    model.create!(name: 'alpha', count: 1, active: true)
    model.create!(name: 'beta',  count: 3, active: false)
    model.api.refresh!
  end

  after { TestIndex.drop! }

  subject(:model) do
    Class.new(ElasticsearchRecord::Base) {
      def self.name = 'ConnectionLeaseSpecModel'
    }.tap { |klass|
      klass.table_name = TestIndex.name
      klass.reset_column_information
    }
  end

  describe 'ActiveRecord.permanent_connection_checkout = :disallowed' do
    around do |example|
      previous = ActiveRecord.permanent_connection_checkout
      ActiveRecord.permanent_connection_checkout = :disallowed
      example.run
    ensure
      ActiveRecord.permanent_connection_checkout = previous
    end

    # the main thread already holds a permanent lease (the spec support resolves it through
    # +ElasticsearchRecord::Base.connection+), which silences the check - a FRESH thread does not
    def in_fresh_thread(&block)
      Thread.new(&block).tap { |thread| thread.report_on_exception = false }.value
    end

    it 'raises for a direct Model.connection call (sanity check of the setup)' do
      expect { in_fresh_thread { model.connection } }
        .to raise_error(ActiveRecord::ActiveRecordError, /deprecated `ActiveRecord::Base.connection`/)
    end

    it 'never resolves the connection through Model.connection' do
      expect {
        in_fresh_thread do
          # model schema (uncached values)
          model.reset_column_information
          model.table_name_prefix
          model.max_result_window
          model.auto_increment?

          # persistence
          record = model.create!(name: 'gamma', count: 5, active: true)
          record.update!(count: 6)
          record.destroy!

          # relation: load, calculation, ordering & PIT
          model.where(active: true).to_a
          model.where(active: true).count
          model.limit(1).count
          model.first
          model.order(:count).last
          # an unordered +last+ checks the cluster's '_id' fielddata access first
          begin
            model.last
          rescue ActiveRecord::IrreversibleOrderError
            nil
          end
          model.all.pit_results(batch_size: 1)
          model.where(name: 'nope').pit_delete(batch_size: 1)

          # querying & api
          model.msearch([{ query: { match_all: {} } }])
          model.api.refresh!
          model.api.bulk({ _id: 'x1', name: 'delta' })
        end
      }.not_to raise_error
    end
  end

  # +table_name_prefix+ & +table_name_suffix+ are CONFIG extras of the elasticsearch adapter - but
  # resolving them through the adapter would lease a connection for a plain config lookup, and
  # +table_name+ is resolved on class definition & on every schema access.
  describe '.table_name_prefix & .table_name_suffix' do
    def db_config_with(**extras)
      ActiveRecord::DatabaseConfigurations::HashConfig.new(
        'test', 'elasticsearch', ElasticsearchSpec::CONFIG.symbolize_keys.merge(**extras))
    end

    it 'resolves both values from the connection config' do
      allow(model).to receive(:connection_db_config)
                        .and_return(db_config_with(table_name_prefix: 'pre_', table_name_suffix: '_suf'))

      expect(model.table_name_prefix).to eq('pre_')
      expect(model.table_name_suffix).to eq('_suf')
    end

    it 'defaults to an empty String' do
      allow(model).to receive(:connection_db_config).and_return(db_config_with)

      expect(model.table_name_prefix).to eq('')
      expect(model.table_name_suffix).to eq('')
    end

    # an explicitly assigned value always wins - the config only provides the fallback
    it 'keeps an explicitly assigned prefix & suffix' do
      allow(model).to receive(:connection_db_config)
                        .and_return(db_config_with(table_name_prefix: 'pre_', table_name_suffix: '_suf'))
      model.table_name_prefix = 'own_'
      model.table_name_suffix = '_own'

      expect(model.table_name_prefix).to eq('own_')
      expect(model.table_name_suffix).to eq('_own')
    end

    it 'does not check a connection out of the pool' do
      leased = Thread.new {
        model.table_name_prefix
        model.table_name_suffix

        !!model.connection_pool.active_connection?
      }.value

      expect(leased).to be(false)
    end
  end

  # +with_connection+ is re-entrant: a nested call reuses the connection that is already leased to
  # the current thread instead of checking out a second one. Several methods rely on that - e.g.
  # +pit_results+ resolves +access_shard_doc?+ (and with it the adapters +cluster_info+) through its
  # own +with_connection+ while iterating.
  # see @ ActiveRecord::ConnectionAdapters::ConnectionPool#with_connection
  describe 'nested with_connection' do
    # every example runs in a FRESH thread - the main thread holds a permanent lease (spec support),
    # which would make every checkout a reuse anyway
    def in_fresh_thread(&block)
      Thread.new(&block).value
    end

    it 'leases one connection only' do
      checkouts, connections = in_fresh_thread do
        count = 0
        seen  = []

        model.connection_pool.singleton_class.prepend(Module.new do
          define_method(:checkout) { |*args, **opts, &blk| count += 1; super(*args, **opts, &blk) }
        end)

        model.with_connection do |outer|
          seen << outer
          model.with_connection do |middle|
            seen << middle
            model.with_connection { |inner| seen << inner }
          end
        end

        [count, seen]
      end

      expect(checkouts).to eq(1)
      expect(connections.uniq.size).to eq(1)
    end

    it 'resolves the adapter flags of a running pit_results without a second checkout' do
      leased_twice = in_fresh_thread do
        model.with_connection do |connection|
          # force the flags to be resolved from the cluster again
          connection.instance_variable_set(:@access_shard_doc, nil)
          connection.instance_variable_set(:@cluster_info, nil)

          # a busy pool would hand a SECOND connection to a nested checkout
          before = model.connection_pool.stat[:busy]
          model.all.pit_results(batch_size: 1)

          model.connection_pool.stat[:busy] > before
        end
      end

      expect(leased_twice).to be(false)
    end

    # rails resolves its own batching the same way - a lease per query, never one across the
    # caller's block (see @ ActiveRecord::Batches). Holding one would block a pool connection for
    # as long as the provided block runs.
    it 'does not hold a connection while the pit_results block runs' do
      leased = in_fresh_thread do
        held = []
        model.all.pit_results(batch_size: 1) { |results| held << !!model.connection_pool.active_connection?; results }
        held
      end

      expect(leased).to be_present
      expect(leased).to all(be(false))
    end
  end

  describe '.auto_increment?' do
    def count_mapping_requests
      count = 0
      callback = ->(*, payload) { count += 1 if payload[:gate] == 'indices.get_mapping' }

      ActiveSupport::Notifications.subscribed(callback, 'query.elasticsearch_record') { yield }

      count
    end

    # a +||=+ never memoizes +false+ - a regular index resolved its mapping on EVERY insert
    it 'resolves a false status only once' do
      # the inserts of the +before+ hook already resolved it
      model.reset_column_information

      expect(count_mapping_requests { 3.times { expect(model.auto_increment?).to be(false) } }).to eq(1)
    end

    it 'does not resolve the mapping again for further inserts' do
      model.auto_increment?

      expect(count_mapping_requests { model.create!(name: 'gamma') }).to eq(0)
    end

    it 'resolves the status again after reset_column_information' do
      model.auto_increment?
      model.reset_column_information

      expect(count_mapping_requests { model.auto_increment? }).to eq(1)
    end
  end
end
