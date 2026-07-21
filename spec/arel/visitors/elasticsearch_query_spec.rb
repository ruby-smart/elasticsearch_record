# frozen_string_literal: true

RSpec.describe Arel::Visitors::Elasticsearch do
  subject(:visitor) { described_class.new(connection) }

  let(:connection) { instance_double(ActiveRecord::ConnectionAdapters::ElasticsearchAdapter) }
  let(:table) { Arel::Table.new('schema_migrations') }

  describe '#visit_Arel_Nodes_InsertStatement' do
    context 'with plain values (the rails 7.1 SchemaMigration#create_version shape)' do
      # +Arel::InsertManager#insert+ splits a "column => plain value" Hash into the
      # statement columns & a ValuesList of raw values - the pairs must be restored by position.
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

    context 'with attribute values (the ActiveRecord persistence shape)' do
      it 'resolves name & value from each attribute' do
        attribute = ActiveModel::Attribute.from_user('version', '20221212122912', ActiveModel::Type::String.new)

        im = Arel::InsertManager.new(table)
        im.insert(table['version'] => attribute)

        query = visitor.compile(im.ast)

        expect(query.type).to eq(ElasticsearchRecord::Query::TYPE_CREATE)
        expect(query.body).to eq({ 'version' => '20221212122912' })
      end
    end
  end
end
