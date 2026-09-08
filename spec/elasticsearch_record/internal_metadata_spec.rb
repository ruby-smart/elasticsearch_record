# frozen_string_literal: true

# Covers +ElasticsearchRecord::InternalMetadata#enabled?+ - the single method of the class.
#
# Elasticsearch cannot serve the 'ar_internal_metadata' table (see
# +ElasticsearchAdapter#use_metadata_table?+). Up to rails 7.1 that adapter flag was enough, but
# since 7.2 +ActiveRecord::InternalMetadata#enabled?+ resolves the flag from the DATABASE CONFIG
# (+use_metadata_table+, default: true) and never asks the adapter - so a default configuration
# would suddenly create & write an 'ar_internal_metadata' index on the cluster.
#
# The override hardwires +false+, which short-circuits +#[]+, +#[]=+, +#create_table+,
# +#create_table_and_set_flags+ & +#drop_table+ of the parent class.
#
# SAFETY: the examples that reach the cluster point +internal_metadata_table_name+ into the test
# namespace (+TestIndex::ALLOWED+) first. A REGRESSION of +#enabled?+ would otherwise actually
# create the metadata index - and the suite must never leave one behind on the shared cluster.
#
# see @ ElasticsearchRecord::InternalMetadata
# see @ ActiveRecord::InternalMetadata
RSpec.describe ElasticsearchRecord::InternalMetadata do
  subject(:internal_metadata) { described_class.new(pool) }

  let(:pool) { ElasticsearchRecord::Base.connection_pool }

  describe '#enabled?' do
    it 'is always false' do
      expect(internal_metadata.enabled?).to be(false)
    end

    # the config carries the rails DEFAULT (+use_metadata_table+ is not set) - which is exactly
    # the case the override exists for: the parent class would return true here.
    it 'is false although the database config enables the metadata table' do
      expect(pool.db_config.use_metadata_table?).to be(true)
      expect(internal_metadata.enabled?).to be(false)
    end

    it 'differs from the inherited implementation' do
      expect(ActiveRecord::InternalMetadata.new(pool).enabled?).to be(true)
    end

    # the flag is resolved WITHOUT asking the pool - a strict double would raise on any call
    it 'does not consult the pool' do
      expect(described_class.new(instance_double(ActiveRecord::ConnectionAdapters::ConnectionPool)).enabled?)
        .to be(false)
    end

    # since rails 7.2 the migration plumbing resolves the metadata through the POOL - the
    # patched factory has to return this class, otherwise the override never applies.
    # see @ ElasticsearchRecord::Patches::ActiveRecord::ConnectionPoolPatch
    it 'is the implementation the connection pool resolves' do
      expect(pool.internal_metadata).to be_a(described_class)
      expect(pool.internal_metadata.enabled?).to be(false)
    end
  end

  # the disabled flag short-circuits every writing method of the parent class - nothing is
  # sent to the cluster and no metadata index appears.
  describe 'the disabled metadata table', :elasticsearch do
    # PLEASE NOTE: the +:elasticsearch+ tag skips these examples through a +before(:each)+ hook
    # (see spec_helper.rb) - so this must NOT run in a +before(:all)+.
    before { ActiveRecord::Base.internal_metadata_table_name = metadata_table_name }

    after do
      ActiveRecord::Base.internal_metadata_table_name = 'ar_internal_metadata'
      # only reached if +#enabled?+ regressed - the index is dropped either way
      TestIndex.drop!(metadata_table_name)
    end

    let(:connection) { ElasticsearchRecord::Base.connection }

    # stays within +TestIndex::ALLOWED+, so a regression can never create a real metadata index
    let(:metadata_table_name) { "#{TestIndex.name}_metadata" }

    it 'resolves the redirected table name' do
      expect(internal_metadata.table_name).to eq(metadata_table_name)
    end

    it 'does not create the index' do
      internal_metadata.create_table

      expect(connection.table_exists?(metadata_table_name)).to be(false)
    end

    it 'does not create the index while setting the flags' do
      internal_metadata.create_table_and_set_flags('test')

      expect(connection.table_exists?(metadata_table_name)).to be(false)
    end

    it 'does not store an entry' do
      internal_metadata[:environment] = 'test'

      expect(internal_metadata[:environment]).to be_nil
    end
  end
end
