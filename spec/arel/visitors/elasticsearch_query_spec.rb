# frozen_string_literal: true

# Regression specs for the rails 7.1 Arel changes.
#
# Both cases below broke silently on the rails 7.1 upgrade and are pinned here:
# - +Arel::Nodes::HomogeneousIn#column_name+ was removed
# - +InsertManager#insert+ splits "column => plain value" into statement columns
#   and a ValuesList of raw (non attribute-shaped) values
RSpec.describe Arel::Visitors::Elasticsearch do
  subject(:visitor) { described_class.new(connection) }

  let(:connection) { instance_double(ActiveRecord::ConnectionAdapters::ElasticsearchAdapter) }
  let(:table) { Arel::Table.new('schema_migrations') }

  # NOTE: only plain values are exercised below - attribute-shaped values never reach this
  # visitor. +ElasticsearchRecord::Persistence#_insert_record+ unwraps them
  # (+transform_values(&:value)+) and bypasses Arel entirely. The only callers that build an
  # +InsertManager+ are +SchemaMigration#create_version+ & +InternalMetadata#create_entry+,
  # both of which pass plain scalars.
  describe 'insert statements' do
    context 'with plain values (the rails 7.1 SchemaMigration#create_version shape)' do
      # +Arel::InsertManager#insert+ splits a "column => plain value" Hash into the
      # statement columns & a ValuesList of raw values - the pairs are restored by
      # position in +#visit_Create+.
      it 'zips the values with the statement columns' do
        im = Arel::InsertManager.new(table)
        im.insert(table['version'] => '20221212122912')

        query = visitor.compile(im.ast)

        expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_CREATE)
        expect(query.index).to eq('schema_migrations')
        expect(query.body).to eq({ 'version' => '20221212122912' })
      end

      it 'keeps multiple columns in positional order' do
        im = Arel::InsertManager.new(table)
        im.insert([[table['version'], '20221212122912'], [table['direction'], 'up']])

        query = visitor.compile(im.ast)

        expect(query.body).to eq({ 'version' => '20221212122912', 'direction' => 'up' })
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

        im = Arel::InsertManager.new(table)
        im.insert(table['version'] => attribute)

        query = visitor.compile(im.ast)

        expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_CREATE)
        expect(query.body['version']).to be(attribute)
      end
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
  end
end
