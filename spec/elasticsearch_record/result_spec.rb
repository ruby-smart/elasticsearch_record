# frozen_string_literal: true

# Covers the PARTIAL-result surface of +ElasticsearchRecord::Result+.
#
# Since Elasticsearch 8.19 an ES|QL query no longer fails when it cannot reach all of its data
# (e.g. an unavailable shard) - it succeeds with whatever it could collect and only raises the
# +is_partial+ flag. A caller that does not check it silently works on an INCOMPLETE result-set,
# so the flag has to be readable from the result object.
#
# see @ https://www.elastic.co/guide/en/elasticsearch/reference/8.19/migrating-8.19.html
# see @ ElasticsearchRecord::Result#partial?
# see @ ElasticsearchRecord.error_on_partial_results
RSpec.describe ElasticsearchRecord::Result do
  # a tabular (ES|QL) response - a flat 'columns' definition and positional value rows
  def esql_response(is_partial: nil)
    {
      'took'    => 5,
      'columns' => [{ 'name' => 'name', 'type' => 'keyword' }],
      'values'  => [['alpha'], ['beta']]
    }.tap { |response| response['is_partial'] = is_partial unless is_partial.nil? }
  end

  describe '#partial?' do
    it 'is true when the response was flagged as partial' do
      expect(described_class.new(esql_response(is_partial: true)).partial?).to be(true)
    end

    it 'is false when the response carries a false flag' do
      expect(described_class.new(esql_response(is_partial: false)).partial?).to be(false)
    end

    # a search / count / index response never carries the flag at all
    it 'is false when the response does not carry the flag' do
      expect(described_class.new(esql_response).partial?).to be(false)
      expect(described_class.new({ 'hits' => { 'hits' => [], 'total' => { 'value' => 0 } } }).partial?).to be(false)
    end

    it 'is false on an empty result' do
      expect(described_class.empty.partial?).to be(false)
    end

    # +partial?+ is a pure flag reader - the (incomplete) rows are still returned as-is
    it 'does not affect the returned rows' do
      result = described_class.new(esql_response(is_partial: true))

      expect(result.total).to eq(2)
      expect(result.length).to eq(2)
      expect(result.results).to eq([{ 'name' => 'alpha' }, { 'name' => 'beta' }])
    end
  end

  # an incomplete result-set that nobody notices shows up as MISSING RECORDS, never as an error -
  # so the query fails by default and accepting partial results is the opt-in
  describe 'ElasticsearchRecord.error_on_partial_results' do
    it 'defaults to true' do
      expect(ElasticsearchRecord.error_on_partial_results).to be(true)
    end
  end
end
