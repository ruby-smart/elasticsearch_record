# frozen_string_literal: true

# Regression specs for the internal-metadata table resolution.
#
# These run WITHOUT a cluster: every method that would talk to Elasticsearch is
# stubbed, so only the name-filtering logic is exercised.
RSpec.describe ActiveRecord::ConnectionAdapters::Elasticsearch::TableStatements do
  subject(:adapter) do
    ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.new(ElasticsearchSpec::CONFIG.symbolize_keys)
  end

  # +ElasticsearchRecord::SchemaMigration#table_name+ resolves through +ElasticsearchRecord::Base+,
  # which would require a live connection - the name is all these specs need.
  before do
    allow(adapter).to receive(:schema_migration)
                        .and_return(instance_double(ElasticsearchRecord::SchemaMigration, table_name: 'schema_migrations'))
  end

  # rails 7.1 turned +ActiveRecord::InternalMetadata+ into a plain, connection-bound class -
  # the former class-level +InternalMetadata.table_name+ is gone and raised a NoMethodError.
  it 'resolves the internal metadata table through the adapter instance' do
    expect(adapter.internal_metadata).to be_an(ActiveRecord::InternalMetadata)
    expect(adapter.internal_metadata.table_name).to eq('ar_internal_metadata')
  end

  # each of the four *_tables methods filters out the two AR-internal indices
  {
    open_tables:     :open_table,
    close_tables:    :close_table,
    refresh_tables:  :refresh_table,
    truncate_tables: :truncate_table
  }.each do |plural, singular|
    describe "##{plural}" do
      before { allow(adapter).to receive(singular) }

      it 'excludes the schema_migrations & internal metadata tables' do
        adapter.public_send(plural, 'schema_migrations', 'ar_internal_metadata', 'some-index')

        expect(adapter).to have_received(singular).with('some-index')
        expect(adapter).not_to have_received(singular).with('schema_migrations')
        expect(adapter).not_to have_received(singular).with('ar_internal_metadata')
      end

      it 'returns nil without calling through when only internal tables were provided' do
        expect(adapter.public_send(plural, 'schema_migrations', 'ar_internal_metadata')).to be_nil
        expect(adapter).not_to have_received(singular)
      end

      it 'maps over every remaining table' do
        adapter.public_send(plural, 'index-a', 'index-b')

        expect(adapter).to have_received(singular).with('index-a')
        expect(adapter).to have_received(singular).with('index-b')
      end
    end
  end
end
