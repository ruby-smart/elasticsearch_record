# frozen_string_literal: true

RSpec.describe ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaStatements do
  subject(:adapter) do
    ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.new({ adapter: 'elasticsearch', host: 'localhost:9200' })
  end

  describe '#assume_migrated_upto_version' do
    # verifying double: fails if the code calls a method that does not exist on the
    # rails 7.1 SchemaMigration API (like the former +create+)
    let(:schema_migration) { instance_double(ElasticsearchRecord::SchemaMigration) }
    let(:migration_context) { instance_double(ActiveRecord::MigrationContext, get_all_versions: [], migrations: []) }

    before do
      allow(adapter).to receive_messages(schema_migration: schema_migration, migration_context: migration_context)
      allow(schema_migration).to receive(:create_version)
    end

    it 'records the version through the SchemaMigration API' do
      adapter.assume_migrated_upto_version(20221212122912)

      expect(schema_migration).to have_received(:create_version).with(20221212122912)
    end
  end
end
