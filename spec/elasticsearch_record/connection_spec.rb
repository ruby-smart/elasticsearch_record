# frozen_string_literal: true

# Verifies that the adapter can talk to a real Elasticsearch cluster.
#
# The cluster is SHARED with other applications - these specs only ever touch
# +TestIndex.name+ ('elasticsearch_record_test') and never drop anything else.
RSpec.describe 'Elasticsearch connection', :elasticsearch do
  subject(:connection) { ElasticsearchSpec.connection }

  describe 'the adapter' do
    it 'is the Elasticsearch adapter' do
      expect(connection).to be_a(ActiveRecord::ConnectionAdapters::ElasticsearchAdapter)
      expect(connection.adapter_name).to eq('Elasticsearch')
    end

    it 'verifies the connection without raising' do
      expect { connection.verify! }.not_to raise_error
    end

    it 'reports that transactions are unsupported' do
      expect(connection.supports_transactions?).to be(false)
    end
  end

  describe 'the cluster' do
    it 'reports its health' do
      expect(connection.cluster_health).to include('status' => a_string_matching(/green|yellow|red/))
    end

    it 'reports cluster info including a version' do
      info = connection.cluster_info

      expect(info).to include(:cluster_name, :version)
      # the adapter parses the reported version into a Gem::Version
      expect(info[:version]).to be_a(Gem::Version)
      expect(info[:version]).to be >= Gem::Version.new('7.17')
    end
  end

  describe 'the test index' do
    before { TestIndex.create! }
    after  { TestIndex.drop! }

    it 'is created and visible to the adapter' do
      expect(connection.table_exists?(TestIndex.name)).to be(true)
      expect(connection.tables).to include(TestIndex.name)
    end

    it 'exposes the mapping that was created' do
      mappings = connection.table_mappings(TestIndex.name)

      expect(mappings['properties'].keys).to include('name', 'count', 'active', 'created_at')
      expect(mappings['properties']['name']['type']).to eq('keyword')
      expect(mappings['properties']['count']['type']).to eq('integer')
    end

    it 'exposes the settings that were created' do
      # settings come back flattened, with dotted keys
      settings = connection.table_settings(TestIndex.name)

      expect(settings['index.number_of_shards']).to eq('1')
      expect(settings['index.number_of_replicas']).to eq('0')
      expect(settings['index.provided_name']).to eq(TestIndex.name)
    end

    it 'round-trips a document through the model API' do
      model = Class.new(ElasticsearchRecord::Base) do
        # anonymous class - table name must be set explicitly
        def self.name = 'ConnectionSpecModel'
      end
      model.table_name = TestIndex.name

      record = model.create!(name: 'connection-check', count: 42, active: true)
      model.api.refresh!

      expect(record).to be_persisted
      expect(model.where(name: 'connection-check').count).to eq(1)
      expect(model.find(record._id).count).to eq(42)
    end
  end

  describe 'safety' do
    it 'never drops indices belonging to other applications' do
      expect { TestIndex.__send__(:assert_safe!) }.not_to raise_error

      stub_const('ElasticsearchSpec::TEST_INDEX', 'ri-search-development')

      expect { TestIndex.drop! }.to raise_error(TestIndex::UnsafeIndexError, /Refusing to modify/)
    end

    it 'leaves pre-existing indices untouched' do
      before_tables = connection.tables - [TestIndex.name]

      TestIndex.create!
      TestIndex.drop!

      expect(connection.tables - [TestIndex.name]).to match_array(before_tables)
    end
  end
end
