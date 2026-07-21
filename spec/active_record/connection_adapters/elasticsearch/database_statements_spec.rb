# frozen_string_literal: true

RSpec.describe ActiveRecord::ConnectionAdapters::Elasticsearch::DatabaseStatements do
  subject(:adapter) do
    ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.new({ adapter: 'elasticsearch', host: 'localhost:9200' })
  end

  describe '#select_values' do
    # a canned Elasticsearch search response, as returned for
    # +SchemaMigration#versions+ (SELECT version FROM schema_migrations ORDER BY version ASC)
    let(:response) do
      {
        'took' => 1,
        'hits' => {
          'total' => { 'value' => 2, 'relation' => 'eq' },
          'hits'  => [
            { '_index' => 'schema_migrations', '_id' => 'a1', '_score' => 1.0, '_source' => { 'version' => '20221212122912' } },
            { '_index' => 'schema_migrations', '_id' => 'a2', '_score' => 1.0, '_source' => { 'version' => '20230217145100' } }
          ]
        }
      }
    end

    let(:result) { ElasticsearchRecord::Result.new(response, ['version']) }

    before do
      allow(adapter).to receive(:select_all).and_return(result)
    end

    it 'returns plain values of the first column (not [field, value] pairs)' do
      expect(adapter.select_values(:some_arel, 'SCHEMA')).to eq(%w[20221212122912 20230217145100])
    end
  end
end
