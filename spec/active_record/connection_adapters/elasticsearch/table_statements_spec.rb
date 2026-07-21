# frozen_string_literal: true

RSpec.describe ActiveRecord::ConnectionAdapters::Elasticsearch::TableStatements do
  subject(:adapter) do
    ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.new({ adapter: 'elasticsearch', host: 'localhost:9200' })
  end

  before do
    # +ElasticsearchRecord::SchemaMigration#table_name+ resolves through +ElasticsearchRecord::Base+,
    # which requires a configured database connection - not available in a plain gem spec
    allow(adapter).to receive(:schema_migration)
                        .and_return(instance_double(ElasticsearchRecord::SchemaMigration, table_name: 'schema_migrations'))
  end

  describe '#truncate_tables' do
    before do
      allow(adapter).to receive(:truncate_table)
    end

    # regression: resolving the internal metadata table through the class method
    # +InternalMetadata.table_name+ raises a NoMethodError on rails 7.1 (instance-based API)
    it 'excludes the schema_migrations & internal metadata tables' do
      adapter.truncate_tables('schema_migrations', 'ar_internal_metadata', 'some-index')

      expect(adapter).to have_received(:truncate_table).with('some-index')
      expect(adapter).not_to have_received(:truncate_table).with('schema_migrations')
      expect(adapter).not_to have_received(:truncate_table).with('ar_internal_metadata')
    end
  end

  describe '#refresh_tables' do
    before do
      allow(adapter).to receive(:refresh_table)
    end

    it 'excludes the schema_migrations & internal metadata tables' do
      adapter.refresh_tables('ar_internal_metadata', 'some-index')

      expect(adapter).to have_received(:refresh_table).with('some-index')
      expect(adapter).not_to have_received(:refresh_table).with('ar_internal_metadata')
    end
  end
end
