# frozen_string_literal: true

# Regression specs for +select_values+ / +select_rows+.
#
# The adapter does NOT override +select_values+ - the AbstractAdapter default
# (+select_rows(...).map(&:first)+) is used, which relies on
# +ElasticsearchRecord::Result#rows+ returning positional value-arrays.
# If +#rows+ ever returned +field => value+ hashes again, +SchemaMigration#versions+
# would break ('undefined method to_i for an instance of Array'), so the contract
# is pinned here.
RSpec.describe ActiveRecord::ConnectionAdapters::Elasticsearch::DatabaseStatements do
  subject(:adapter) do
    ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.new(ElasticsearchSpec::CONFIG.symbolize_keys)
  end

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

  describe '#select_values' do
    context 'with provided columns' do
      before do
        allow(adapter).to receive(:select_all)
                            .and_return(ElasticsearchRecord::Result.new(response, ['version']))
      end

      it 'returns plain values of the first column (not [field, value] pairs)' do
        expect(adapter.select_values(:some_arel, 'SCHEMA')).to eq(%w[20221212122912 20230217145100])
      end

      it 'returns values that are usable as migration versions' do
        expect(adapter.select_values(:some_arel, 'SCHEMA').map(&:to_i))
          .to eq([20221212122912, 20230217145100])
      end
    end

    # without columns +#rows+ falls back to the raw +_source+ values - the values
    # must still come back plain, never as [field, value] pairs.
    context 'without provided columns' do
      before do
        allow(adapter).to receive(:select_all)
                            .and_return(ElasticsearchRecord::Result.new(response, []))
      end

      it 'falls back to the raw _source values' do
        expect(adapter.select_values(:some_arel, 'SCHEMA')).to eq(%w[20221212122912 20230217145100])
      end
    end
  end

  describe '#select_rows' do
    before do
      allow(adapter).to receive(:select_all)
                          .and_return(ElasticsearchRecord::Result.new(response, ['version']))
    end

    it 'returns positional value-arrays' do
      expect(adapter.select_rows(:some_arel, 'SCHEMA')).to eq([['20221212122912'], ['20230217145100']])
    end
  end
end
