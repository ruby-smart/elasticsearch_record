# frozen_string_literal: true

# Covers +ActiveRecord::ConnectionAdapters::Elasticsearch::Column+.
#
# The column is plain Ruby - no cluster is involved, so every example builds the object directly
# the way +SchemaStatements#new_column_from_field+ does.
#
# The interesting part is IDENTITY: ActiveRecord keeps a single column object per process for
# columns that compare equal (+Deduplicable#deduplicate+ -> +registry[self] ||= deduplicated+).
# The base +Column#==+ & +#hash+ only know about name, default, type metadata, null, default
# function, collation & comment - so the elasticsearch-specific attributes MUST be part of the
# comparison, otherwise two same-named columns of DIFFERENT indexes share one object.
#
# see @ ActiveRecord::ConnectionAdapters::Elasticsearch::Column
# see @ ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaStatements#new_column_from_field
RSpec.describe ActiveRecord::ConnectionAdapters::Elasticsearch::Column do
  let(:sql_type_metadata) do
    ActiveRecord::ConnectionAdapters::SqlTypeMetadata.new(sql_type: 'keyword', type: :string)
  end

  # builds a 'code' keyword column - the +fields+ are the only thing that differs between the
  # indexes that triggered this
  def build_column(name = 'code', **kwargs)
    described_class.new(name, nil, sql_type_metadata, **kwargs)
  end

  # the sub-field a 'code' keyword usually carries: +code.analyzed+
  let(:analyzed_field) { [{ 'name' => 'analyzed', 'type' => 'text' }] }

  ############
  # DEFAULTS #
  ############

  describe '#initialize' do
    subject(:column) { build_column }

    it 'defaults the elasticsearch-specific attributes' do
      expect(column.virtual).to be(false)
      expect(column.fields).to eq([])
      expect(column.properties).to eq([])
      expect(column.meta).to eq({})
      expect(column.enabled).to be(true)
    end
  end

  ############
  # IDENTITY #
  ############

  describe '#==' do
    it 'is equal for two identical columns' do
      expect(build_column).to eq(build_column)
    end

    # the regression: a 'code' keyword WITH a 'analyzed' sub-field is NOT the same column as a
    # 'code' keyword without one - the base attributes are identical for both
    it 'is not equal when only the fields differ' do
      expect(build_column(fields: analyzed_field)).not_to eq(build_column)
    end

    it 'is not equal when only the properties differ' do
      expect(build_column(properties: [{ 'name' => 'nested', 'type' => 'keyword' }])).not_to eq(build_column)
    end

    it 'is not equal when only the meta differs' do
      expect(build_column(meta: { 'comment' => 'a code' })).not_to eq(build_column)
    end

    it 'is not equal when only the virtual flag differs' do
      expect(build_column(virtual: true)).not_to eq(build_column)
    end

    it 'is not equal when only the enabled flag differs' do
      expect(build_column(enabled: false)).not_to eq(build_column)
    end

    it 'is not equal to a base column' do
      base = ActiveRecord::ConnectionAdapters::Column.new('code', nil, sql_type_metadata)

      expect(build_column).not_to eq(base)
    end
  end

  describe '#hash' do
    it 'is the same for two identical columns' do
      expect(build_column.hash).to eq(build_column.hash)
    end

    it 'differs when the elasticsearch-specific attributes differ' do
      expect(build_column(fields: analyzed_field).hash).not_to eq(build_column.hash)
      expect(build_column(properties: [{ 'name' => 'nested' }]).hash).not_to eq(build_column.hash)
      expect(build_column(meta: { 'comment' => 'a code' }).hash).not_to eq(build_column.hash)
      expect(build_column(virtual: true).hash).not_to eq(build_column.hash)
      expect(build_column(enabled: false).hash).not_to eq(build_column.hash)
    end
  end

  # +Deduplicable+ hooks into +.new+ - this is what actually broke: whichever index loaded its
  # schema first won, and the other one silently gained or lost its +fields+ for the whole process
  describe 'deduplication' do
    it 'reuses the object for two identical columns' do
      expect(build_column).to equal(build_column)
    end

    it 'keeps a column with fields apart from one without' do
      without = build_column
      with    = build_column(fields: analyzed_field)

      expect(with).not_to equal(without)
      expect(without.field_names).to eq([])
      expect(with.field_names).to eq(['analyzed'])
    end

    # the order must not matter - loading the field-less index first used to strip 'code.analyzed'
    # from every other index
    it 'keeps them apart in the reverse order' do
      with    = build_column('reverse_code', fields: analyzed_field)
      without = build_column('reverse_code')

      expect(without).not_to equal(with)
      expect(with.field_names).to eq(['analyzed'])
      expect(without.field_names).to eq([])
    end
  end

  #################
  # SERIALIZATION #
  #################

  # a dumped schema cache round-trips through +#encode_with+ / +#init_with+ - the base only
  # serializes its own attributes, so the elasticsearch ones have to be added
  describe 'YAML round-trip' do
    it 'keeps the elasticsearch-specific attributes' do
      column = build_column(fields: analyzed_field, meta: { 'comment' => 'a code' }, virtual: true, enabled: false)
      dumped = YAML.dump(column)
      loaded = YAML.unsafe_load(dumped)

      expect(loaded.fields).to eq(analyzed_field)
      expect(loaded.meta).to eq({ 'comment' => 'a code' })
      expect(loaded.virtual).to be(true)
      expect(loaded.enabled).to be(false)
      expect(loaded.name).to eq('code')
    end
  end
end
