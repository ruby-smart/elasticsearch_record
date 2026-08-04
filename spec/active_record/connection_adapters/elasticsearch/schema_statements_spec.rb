# frozen_string_literal: true

# Regression spec for the rails 7.1 SchemaMigration API.
#
# rails 7.1 replaced the ActiveRecord-model based SchemaMigration with a plain,
# connection-bound class - the former +create(version:)+ is gone and version
# recording goes through +create_version(version)+.
RSpec.describe ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaStatements do
  subject(:adapter) do
    ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.new(ElasticsearchSpec::CONFIG.symbolize_keys)
  end

  describe '#assume_migrated_upto_version' do
    # verifying double: fails if the code calls a method that does not exist on the
    # rails 7.1 SchemaMigration API (like the former +create+)
    let(:schema_migration) { instance_double(ElasticsearchRecord::SchemaMigration) }

    before do
      allow(adapter).to receive_messages(schema_migration: schema_migration, migration_context: migration_context)
      allow(schema_migration).to receive(:create_version)
    end

    context 'with no migrated versions' do
      let(:migration_context) do
        instance_double(ActiveRecord::MigrationContext, get_all_versions: [], migrations: [])
      end

      it 'records the version through the SchemaMigration API' do
        adapter.assume_migrated_upto_version(20221212122912)

        expect(schema_migration).to have_received(:create_version).with(20221212122912)
      end
    end

    context 'with earlier, not yet migrated versions' do
      let(:migration_context) do
        instance_double(ActiveRecord::MigrationContext,
                        get_all_versions: [],
                        migrations:       [double(version: 20200101000000), double(version: 20210101000000)])
      end

      it 'also records every earlier version' do
        adapter.assume_migrated_upto_version(20221212122912)

        expect(schema_migration).to have_received(:create_version).with(20221212122912)
        expect(schema_migration).to have_received(:create_version).with(20200101000000)
        expect(schema_migration).to have_received(:create_version).with(20210101000000)
      end
    end

    context 'when the version was already migrated' do
      let(:migration_context) do
        instance_double(ActiveRecord::MigrationContext,
                        get_all_versions: [20221212122912],
                        migrations:       [])
      end

      it 'does not record it again' do
        adapter.assume_migrated_upto_version(20221212122912)

        expect(schema_migration).not_to have_received(:create_version).with(20221212122912)
      end
    end
  end
end
