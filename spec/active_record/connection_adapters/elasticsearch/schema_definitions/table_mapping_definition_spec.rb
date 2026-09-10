# frozen_string_literal: true

# Covers the ATTRIBUTE allowlist of
# +ActiveRecord::ConnectionAdapters::Elasticsearch::TableMappingDefinition+.
#
# A mapping definition is a name/type pair plus the mapping PARAMETERS of the field. The parameters
# are validated against +ATTRIBUTES+, which is split in two:
#
# - +COMMON_ATTRIBUTES+ - the parameters that are common to some or all field types
#   (see @ https://www.elastic.co/guide/en/elasticsearch/reference/current/mapping-params.html)
# - +TYPE_ATTRIBUTES+   - the parameters that are only documented on the individual field type
#
# The second group is what makes a lot of types mappable at all: +scaling_factor+ (scaled_float),
# +dims+ (dense_vector) and +metrics+ (aggregate_metric_double) are even REQUIRED by Elasticsearch.
#
# PLEASE NOTE: the validation only ever RAISES in a +strict:+ block - a regular +create_table+
# passes an unknown parameter straight through to Elasticsearch, which is what lets a brand-new
# mapping parameter be used before this gem knows about it.
# see @ ActiveRecord::ConnectionAdapters::Elasticsearch::TableDefinition#mapping
#
# The class is plain Ruby - no cluster is involved.
#
# see @ ActiveRecord::ConnectionAdapters::Elasticsearch::TableMappingDefinition
RSpec.describe ActiveRecord::ConnectionAdapters::Elasticsearch::TableMappingDefinition do
  def definition(type, attributes = {})
    described_class.new('field', type, attributes)
  end

  describe 'ATTRIBUTES' do
    it 'is the union of the common & type-specific parameters' do
      expect(described_class::ATTRIBUTES).to eq(
        described_class::COMMON_ATTRIBUTES + described_class::TYPE_ATTRIBUTES
      )
    end

    it 'has no duplicates' do
      expect(described_class::ATTRIBUTES.uniq).to eq(described_class::ATTRIBUTES)
    end
  end

  # every one of these is REQUIRED by Elasticsearch for its type - without them the type could not
  # be mapped through a strict definition at all
  describe 'the required type parameters' do
    {
      'scaled_float'            => { scaling_factor: 100 },
      'dense_vector'            => { dims: 768, element_type: 'float' },
      'aggregate_metric_double' => { metrics: ['min', 'max'], default_metric: 'max' }
    }.each do |type, attributes|
      it "accepts #{attributes.keys.join(' & ')} on a '#{type}'" do
        expect(definition(type, attributes)).to be_valid
      end
    end
  end

  # 'semantic_text' went GA with Elasticsearch 8.18 - its inference & chunking parameters are the
  # entire point of the type
  describe 'the semantic_text parameters' do
    it 'accepts the inference endpoints' do
      expect(definition('semantic_text', { inference_id: 'my-elser', search_inference_id: 'my-e5' }))
        .to be_valid
    end

    it 'accepts the chunking settings' do
      expect(definition('semantic_text', { chunking_settings: { type: 'none' } })).to be_valid
    end
  end

  describe 'the remaining type parameters' do
    {
      'join'              => { relations: { question: 'answer' } },
      'alias'             => { path: 'other_field' },
      'passthrough'       => { priority: 10 },
      'rank_feature'      => { positive_score_impact: false },
      'flattened'         => { depth_limit: 5 },
      'search_as_you_type' => { max_shingle_size: 3 },
      'completion'        => { max_input_length: 50, preserve_separators: true },
      'geo_shape'         => { orientation: 'ccw', ignore_z_value: true },
      'date_nanos'        => { locale: 'de' },
      'keyword'           => { script: "emit('x')", on_script_error: 'continue' }
    }.each do |type, attributes|
      it "accepts #{attributes.keys.join(' & ')} on a '#{type}'" do
        expect(definition(type, attributes)).to be_valid
      end
    end
  end

  # time series data streams & synthetic source - the 8.19 relevant parameters
  describe 'the time series & synthetic source parameters' do
    it 'accepts the time series markers' do
      expect(definition('keyword', { time_series_dimension: true })).to be_valid
      expect(definition('long', { time_series_metric: 'gauge' })).to be_valid
    end

    it 'accepts synthetic_source_keep' do
      expect(definition('keyword', { synthetic_source_keep: 'arrays' })).to be_valid
      expect(definition('object', { synthetic_source_keep: 'arrays' })).to be_valid
    end
  end

  # +#meta+ falls back to an EMPTY hash rather than nil, so the 'no meta on object/nested' guard
  # used to fire on EVERY object & nested mapping - which made them unusable in a strict block
  describe 'the meta validation' do
    it 'accepts an object & nested mapping without any meta' do
      expect(definition('object', { properties: { a: { type: 'keyword' } } })).to be_valid
      expect(definition('nested')).to be_valid
    end

    it 'still rejects a meta on an object or nested mapping' do
      expect(definition('object', { meta: { 'unit' => 'ms' } })).not_to be_valid
      expect(definition('nested', { meta: { 'unit' => 'ms' } })).not_to be_valid
    end

    it 'accepts a meta on a regular mapping' do
      expect(definition('long', { meta: { 'unit' => 'ms' } })).to be_valid
    end

    it 'rejects a meta with a non-string value' do
      expect(definition('long', { meta: { 'unit' => 5 } })).not_to be_valid
    end
  end

  describe 'an unknown parameter' do
    it 'is invalid' do
      mapping = definition('keyword', { nonsense: true })

      expect(mapping).not_to be_valid
      expect(mapping.error_messages).to include('Attributes keys is not included in the list')
    end

    # ... but it is still CARRIED - a non-strict definition hands it to Elasticsearch untouched
    it 'is kept in the attributes' do
      expect(definition('keyword', { nonsense: true }).attributes).to eq({ nonsense: true })
    end
  end
end
