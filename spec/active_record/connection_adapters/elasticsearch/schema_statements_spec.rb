# frozen_string_literal: true

# Covers +ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaStatements+.
#
# The module is the adapter's schema surface: it reads mappings / settings / aliases from the
# cluster, turns them into ActiveRecord columns, and replaces every SQL-shaped schema statement
# that Elasticsearch cannot serve.
#
# The examples are split in two:
# - the ones that need NO cluster (unsupported methods, factories, pure transformations)
# - a +:elasticsearch+ tagged context that reads a purpose-built index
#
# see @ ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaStatements
RSpec.describe ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaStatements do
  subject(:adapter) do
    ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.new(ElasticsearchSpec::CONFIG.symbolize_keys)
  end

  #####################
  # WITHOUT A CLUSTER #
  #####################

  # +UnsupportedImplementation#define_unsupported_method+ generates these - they must fail LOUDLY
  # instead of silently doing nothing, since none of them has an Elasticsearch equivalent.
  # see @ ActiveRecord::ConnectionAdapters::Elasticsearch::UnsupportedImplementation
  describe 'the unsupported methods' do
    %i[views view_exists? add_index remove_index rename_index add_reference remove_reference
       add_foreign_key remove_foreign_key add_check_constraint remove_check_constraint
       rename_table_indexes rename_column_indexes create_alter_table insert_fixture
       insert_fixtures_set bulk_change_table dump_schema_information].each do |method|
      it "##{method} raises a NotImplementedError" do
        expect { adapter.public_send(method) }
          .to raise_error(NotImplementedError, /'##{Regexp.escape(method.to_s)}' is originally defined by/)
      end
    end
  end

  describe '#type_to_sql' do
    # 'sql' is a misnomer here - it resolves the ELASTICSEARCH mapping type
    it 'resolves a native database type' do
      expect(adapter.type_to_sql(:string)).to eq('keyword')
      expect(adapter.type_to_sql(:datetime)).to eq('date')
    end

    it 'accepts a provided String' do
      expect(adapter.type_to_sql('integer')).to eq('integer')
    end

    # an unmapped type is passed through - Elasticsearch keeps adding types, and a new one must
    # not be swallowed just because +NATIVE_DATABASE_TYPES+ does not know it yet
    it 'passes an unmapped type through' do
      expect(adapter.type_to_sql(:some_future_type)).to eq('some_future_type')
    end

    it 'returns an empty String for a blank type' do
      expect(adapter.type_to_sql(nil)).to eq('')
      expect(adapter.type_to_sql('')).to eq('')
    end
  end

  describe '#tables' do
    # system indices start with a dot - they are data sources, but never model-backed tables
    it 'rejects the system dot indices from the data sources' do
      allow(adapter).to receive(:data_sources).and_return(%w[.security-7 my-index .kibana other-index])

      expect(adapter.tables).to eq(%w[my-index other-index])
    end

    it 'keeps every regular index' do
      allow(adapter).to receive(:data_sources).and_return(%w[a b])

      expect(adapter.tables).to eq(%w[a b])
    end
  end

  describe 'the elasticsearch factories' do
    {
      create_table_definition: ActiveRecord::ConnectionAdapters::Elasticsearch::CreateTableDefinition,
      update_table_definition: ActiveRecord::ConnectionAdapters::Elasticsearch::UpdateTableDefinition
    }.each do |method, klass|
      it "##{method} builds a #{klass.name.demodulize}" do
        expect(adapter.public_send(method, 'my-index')).to be_a(klass)
      end
    end

    it '#schema_creation builds the elasticsearch SchemaCreation' do
      expect(adapter.schema_creation).to be_a(ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaCreation)
    end

    it '#create_schema_dumper builds the elasticsearch SchemaDumper' do
      expect(adapter.create_schema_dumper({}))
        .to be_a(ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaDumper)
    end
  end

  describe '#extract_table_options!' do
    # the elasticsearch specific keys are REMOVED from the provided options - everything else
    # stays behind for the regular table definition
    it 'extracts the elasticsearch keys and mutates the provided Hash' do
      options = { settings: 1, mappings: 2, aliases: 3, metas: 4, force: 5, strict: 6, other: 7 }

      extracted = adapter.send(:extract_table_options!, options)

      expect(extracted).to eq({ settings: 1, mappings: 2, aliases: 3, metas: 4, force: 5, strict: 6 })
      expect(options).to eq({ other: 7 })
    end

    it 'returns an empty Hash without any elasticsearch key' do
      expect(adapter.send(:extract_table_options!, { other: 1 })).to eq({})
    end
  end

  # Regression spec for the rails 7.1 SchemaMigration API.
  #
  # rails 7.1 replaced the ActiveRecord-model based SchemaMigration with a plain,
  # connection-bound class - the former +create(version:)+ is gone and version
  # recording goes through +create_version(version)+.
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

    context 'with a duplicated migration version' do
      let(:migration_context) do
        instance_double(ActiveRecord::MigrationContext,
                        get_all_versions: [],
                        migrations:       [double(version: 20200101000000), double(version: 20200101000000)])
      end

      it 'raises' do
        expect { adapter.assume_migrated_upto_version(20221212122912) }
          .to raise_error(RuntimeError, /Duplicate migration 20200101000000/)
      end
    end
  end

  ########################
  # AGAINST A REAL INDEX #
  ########################

  # PLEASE NOTE: the +:elasticsearch+ tag skips these examples through a +before(:each)+ hook
  # (see spec_helper.rb) - so the index setup must NOT run in a +before(:all)+, which would
  # execute before that hook and blow up instead of skipping.
  context 'against a real index', :elasticsearch do
    # a dedicated index, so the default +TestIndex+ mapping used by the other specs stays untouched
    let(:index_name) { "#{TestIndex.name}_schema" }

    # a second, deliberately minimal index for the "without ..." branches
    let(:plain_index_name) { "#{TestIndex.name}_plain" }

    before do
      TestIndex.create!(index_name) do |t|
        t.mapping :name, :text do |m|
          m.fields = { keyword: { type: 'keyword' } }
        end
        t.mapping :count, :integer
        t.mapping :user, :object do |m|
          m.properties = { id: { type: 'integer' }, tag: { type: 'keyword', fields: { raw: { type: 'text' } } } }
        end
        t.mapping :uuid, :keyword, meta: { primary_key: 'true' }

        t.setting 'index.number_of_shards', 1
        t.setting 'index.max_result_window', 500

        t.add_alias 'my-alias', is_hidden: true
        t.meta :kind, 'demo'
      end
    end

    after do
      TestIndex.drop!(index_name)
      TestIndex.drop!(plain_index_name)
    end

    # creates the minimal index on demand
    def create_plain_index!(&block)
      TestIndex.create!(plain_index_name, &(block || proc { |t| t.mapping :a, :keyword }))
    end

    describe '#table_mappings' do
      it 'returns the raw mappings node' do
        mappings = adapter.table_mappings(index_name)

        expect(mappings['properties'].keys).to match_array(%w[name count user uuid])
        expect(mappings['properties']['count']).to eq({ 'type' => 'integer' })
      end

      it 'includes the _meta node' do
        expect(adapter.table_mappings(index_name)['_meta']).to eq({ 'kind' => 'demo' })
      end
    end

    describe '#table_metas' do
      it 'chops the _meta node out of the mappings' do
        expect(adapter.table_metas(index_name)).to eq({ 'kind' => 'demo' })
      end

      it 'returns an empty Hash without any meta' do
        create_plain_index!

        expect(adapter.table_metas(plain_index_name)).to eq({})
      end
    end

    describe '#table_settings' do
      # the FLAT form is the default - every key is a full dotted path
      it 'returns flat settings by default' do
        settings = adapter.table_settings(index_name)

        expect(settings['index.number_of_shards']).to eq('1')
        expect(settings['index.max_result_window']).to eq('500')
      end

      it 'returns nested settings when the flat flag is disabled' do
        settings = adapter.table_settings(index_name, false)

        expect(settings.dig('index', 'number_of_shards')).to eq('1')
        expect(settings.dig('index', 'max_result_window')).to eq('500')
      end
    end

    describe '#table_aliases' do
      it 'returns the aliases with their attributes' do
        expect(adapter.table_aliases(index_name)).to eq({ 'my-alias' => { 'is_hidden' => true } })
      end
    end

    describe '#table_state' do
      # the +cat.indices+ response is a positional String - it is zipped into a Hash here
      it 'zips the cat response into a Hash' do
        state = adapter.table_state(index_name)

        expect(state.keys).to eq(%i[health status name uuid pri rep docs_count docs_deleted store_size pri_store_size])
        expect(state[:name]).to eq(index_name)
        expect(state[:status]).to eq('open')
        expect(state[:docs_count]).to eq('0')
      end
    end

    describe '#table_schema' do
      it 'returns settings, mappings & aliases' do
        schema = adapter.table_schema(index_name)

        expect(schema.keys).to eq(%i[settings mappings aliases])
        expect(schema[:settings]['index.max_result_window']).to eq('500')
        expect(schema[:mappings]['properties'].keys).to include('name')
        expect(schema[:aliases]).to eq({ 'my-alias' => { 'is_hidden' => true } })
      end

      # the 'features' argument only exists from cluster version 8.5.0 - below that the whole
      # index is requested and every node is returned regardless
      it 'requests only the provided features' do
        schema = adapter.table_schema(index_name, [:mappings])

        expect(schema[:mappings]).to be_present
        # the omitted nodes come back EMPTY (not missing), so the returned Hash keeps its shape
        expect(schema[:settings]).to be_blank if adapter.cluster_info[:version] >= Gem::Version.new('8.5.0')
      end

      # below 8.5.0 the 'features' argument does not exist - the request is sent without it and
      # every node comes back regardless of what was asked for
      it 'ignores the features on a cluster below 8.5.0' do
        allow(adapter).to receive(:cluster_info).and_return({ version: Gem::Version.new('7.17.0') })

        schema = adapter.table_schema(index_name, [:mappings])

        expect(schema[:mappings]).to be_present
        expect(schema[:settings]).to be_present
        expect(schema[:aliases]).to be_present
      end
    end

    describe '#column_definitions' do
      subject(:definitions) { adapter.column_definitions(index_name) }

      # no mapping ever returns these - they are prepended so the virtual columns stay accessible
      it 'prepends the metadata fields' do
        expect(definitions.first(5).map { |d| d['name'] }).to eq(%w[_id _index _score _type _ignored])
      end

      it 'returns every mapped property' do
        expect(definitions.map { |d| d['name'] }).to eq(%w[_id _index _score _type _ignored count name user uuid])
      end

      # +resolve_fields_and_properties+ flattens the multi-fields into a dotted name
      it 'resolves the multi-fields of a mapping' do
        expect(definitions.find { |d| d['name'] == 'name' }['fields'])
          .to eq([{ 'name' => 'name.keyword', 'type' => 'keyword' }])
      end

      it 'resolves the nested properties of an object mapping' do
        user = definitions.find { |d| d['name'] == 'user' }

        expect(user['properties']).to eq([{ 'name' => 'user.id', 'type' => 'integer' },
                                          { 'name' => 'user.tag', 'type' => 'keyword' }])
      end

      # the fields of a NESTED property are lifted onto the top definition
      it 'resolves the fields of a nested property' do
        expect(definitions.find { |d| d['name'] == 'user' }['fields'])
          .to eq([{ 'name' => 'user.tag.raw', 'type' => 'text' }])
      end

      # elasticsearch omits the type for a pure object mapping
      it 'falls back to the object type for a mapping without a type' do
        expect(definitions.find { |d| d['name'] == 'user' }['type']).to eq('object')
      end

      # without this fallback the index could never be loaded - and therefore never be migrated
      it 'returns only the metadata fields for an index without mappings' do
        create_plain_index! { |_t| }

        expect(adapter.column_definitions(plain_index_name).map { |d| d['name'] })
          .to eq(%w[_id _index _score _type _ignored])
      end
    end

    describe '#new_column_from_field' do
      it 'builds an elasticsearch Column from the definition' do
        field  = adapter.column_definitions(index_name).find { |d| d['name'] == 'name' }
        column = adapter.new_column_from_field(index_name, field, nil)

        expect(column).to be_a(ActiveRecord::ConnectionAdapters::Elasticsearch::Column)
        expect(column.name).to eq('name')
        expect(column.type).to eq(:text)
        expect(column.fields).to eq([{ 'name' => 'name.keyword', 'type' => 'keyword' }])
      end

      it 'flags a metadata field as virtual' do
        field  = adapter.column_definitions(index_name).find { |d| d['name'] == '_score' }
        column = adapter.new_column_from_field(index_name, field, nil)

        expect(column.virtual?).to be(true)
      end

      it 'resolves the cast type upfront and stores it on the column' do
        field  = adapter.column_definitions(index_name).find { |d| d['name'] == 'count' }
        column = adapter.new_column_from_field(index_name, field, nil)

        expect(column.fetch_cast_type(adapter))
          .to be_a(ActiveRecord::ConnectionAdapters::Elasticsearch::Type::MulticastValue)
      end
    end

    # Elasticsearch may return a single value OR an array for ANY type - so every lookup is
    # wrapped into the multicast type
    describe '#lookup_multicast_cast_type' do
      it 'wraps the resolved type into a MulticastValue' do
        column = adapter.columns(index_name).find { |c| c.name == 'count' }

        expect(adapter.lookup_multicast_cast_type(column.sql_type))
          .to be_a(ActiveRecord::ConnectionAdapters::Elasticsearch::Type::MulticastValue)
      end
    end

    describe '#primary_keys' do
      # a mapping flagged through its 'meta' wins over the default '_id'
      it 'resolves a mapping flagged as primary_key' do
        expect(adapter.primary_keys(index_name)).to eq(['uuid'])
      end

      it "falls back to the '_id' metadata field" do
        create_plain_index!

        expect(adapter.primary_keys(plain_index_name)).to eq(['_id'])
      end

      # the index +_meta+ node stores the primary_key as a plain String - it is wrapped, so this
      # branch returns an Array like the two others
      it 'resolves the index _meta primary_key' do
        create_plain_index! do |t|
          t.mapping :uuid, :keyword
          t.meta :primary_key, 'uuid'
        end

        expect(adapter.primary_keys(plain_index_name)).to eq(['uuid'])
        expect(adapter.primary_key(plain_index_name)).to eq('uuid')
      end

      # the index +_meta+ wins over a mapping flagged through its own 'meta'
      it 'prefers the index _meta over a flagged mapping' do
        create_plain_index! do |t|
          t.mapping :uuid, :keyword, meta: { primary_key: 'true' }
          t.mapping :other, :keyword
          t.meta :primary_key, 'other'
        end

        expect(adapter.primary_keys(plain_index_name)).to eq(['other'])
      end

      # every branch returns an Array - +#primary_key+ relies on it (it calls +#size+ / +#first+)
      it 'always returns an Array' do
        create_plain_index!

        expect(adapter.primary_keys(index_name)).to be_an(Array)
        expect(adapter.primary_keys(plain_index_name)).to be_an(Array)
      end
    end

    describe '#data_source_exists? / #table_exists?' do
      it 'is true for an existing index' do
        expect(adapter.data_source_exists?(index_name)).to be(true)
        expect(adapter.table_exists?(index_name)).to be(true)
      end

      it 'is false for a missing index' do
        expect(adapter.data_source_exists?('nope-does-not-exist')).to be(false)
        expect(adapter.table_exists?('nope-does-not-exist')).to be(false)
      end

      it 'accepts a Symbol' do
        expect(adapter.table_exists?(index_name.to_sym)).to be(true)
      end
    end

    describe '#data_sources' do
      it 'includes the created index' do
        expect(adapter.data_sources).to include(index_name)
      end
    end

    # unlike the other factories this one READS from the cluster while it is built - it carries
    # the shard settings of the source index over to the clone
    describe '#clone_table_definition' do
      it 'builds a CloneTableDefinition for an existing source index' do
        definition = adapter.clone_table_definition(index_name, 'my-clone')

        expect(definition).to be_a(ActiveRecord::ConnectionAdapters::Elasticsearch::CloneTableDefinition)
        expect(definition.name).to eq(index_name)
        expect(definition.target).to eq('my-clone')
      end

      it 'carries the shard settings of the source index over' do
        definition = adapter.clone_table_definition(index_name, 'my-clone')

        expect(definition.settings.map(&:name)).to include('index.number_of_shards')
      end
    end

    describe '#alias_exists?' do
      it 'is true for an existing alias' do
        expect(adapter.alias_exists?(index_name, 'my-alias')).to be(true)
      end

      it 'accepts a Symbol' do
        expect(adapter.alias_exists?(index_name, :'my-alias')).to be(true)
      end

      it 'is false for an unknown alias' do
        expect(adapter.alias_exists?(index_name, 'nope')).to be(false)
      end
    end

    describe '#setting_exists?' do
      # the provided name must be FLAT - the settings are looked up in their flat form
      it 'is true for a flat setting name' do
        expect(adapter.setting_exists?(index_name, 'index.number_of_shards')).to be(true)
      end

      it 'is false for a non-flat setting name' do
        expect(adapter.setting_exists?(index_name, 'number_of_shards')).to be(false)
      end
    end

    describe '#mapping_exists?' do
      it 'is true for an existing mapping' do
        expect(adapter.mapping_exists?(index_name, :count)).to be(true)
      end

      it 'also checks the provided type' do
        expect(adapter.mapping_exists?(index_name, :count, :integer)).to be(true)
        expect(adapter.mapping_exists?(index_name, :count, :text)).to be(false)
      end

      it 'is false for an unknown mapping' do
        expect(adapter.mapping_exists?(index_name, :nope)).to be(false)
      end
    end

    describe '#meta_exists?' do
      it 'is true for an existing meta' do
        expect(adapter.meta_exists?(index_name, 'kind')).to be(true)
        expect(adapter.meta_exists?(index_name, :kind)).to be(true)
      end

      it 'is false for an unknown meta' do
        expect(adapter.meta_exists?(index_name, 'nope')).to be(false)
      end
    end

    describe '#max_result_window' do
      it 'resolves the configured index setting' do
        expect(adapter.max_result_window(index_name)).to eq(500)
      end

      it 'falls back to 10000 without a configured setting' do
        create_plain_index!

        expect(adapter.max_result_window(plain_index_name)).to eq(10000)
      end

      # IMPORTANT: the settings API returns every value as a String - without the cast the callers
      # would compare a String against their (Integer) batch sizes:
      # +ResultMethods#composite+ / +#pit_results+ guard the batch_size against it, and
      # +ValueMethods#limit_value=+ hands it to the query as the size.
      # see @ ElasticsearchRecord::Relation::ResultMethods
      it 'always returns an Integer' do
        create_plain_index!

        expect(adapter.max_result_window(index_name)).to be_an(Integer)
        expect(adapter.max_result_window(plain_index_name)).to be_an(Integer)
      end
    end

    describe '#cluster_info' do
      it 'returns the basic cluster information' do
        info = adapter.cluster_info

        expect(info.keys).to eq(%i[name cluster_name cluster_uuid version lucene_version])
        expect(info[:version]).to be_a(Gem::Version)
        expect(info[:cluster_name]).to be_present
      end

      it 'memoizes the response' do
        expect(adapter.cluster_info).to equal(adapter.cluster_info)
      end
    end

    describe '#cluster_settings' do
      # persistent & transient are merged into a single flat Hash
      it 'returns a flat Hash' do
        expect(adapter.cluster_settings).to be_a(Hash)
        expect(adapter.cluster_settings.keys).to all(be_a(String))
      end
    end

    describe '#cluster_health' do
      it 'returns the cluster health' do
        health = adapter.cluster_health

        expect(health['cluster_name']).to be_present
        expect(health['status']).to be_in(%w[green yellow red])
      end
    end

    describe '#access_id_fielddata?' do
      # sorting on the '_id' field is only possible when the cluster allows it
      # see @ ElasticsearchRecord::Relation::CoreMethods#ordered_relation
      it 'resolves the cluster setting' do
        allow(adapter).to receive(:cluster_settings).and_return({ 'indices.id_field_data.enabled' => true })

        expect(adapter.access_id_fielddata?).to be(true)
      end

      # for clusters below 7.6 the setting might not be configured at all - the version decides
      it 'falls back to the cluster version when the setting is missing' do
        allow(adapter).to receive(:cluster_settings).and_return({})

        expect(adapter.access_id_fielddata?).to be(adapter.cluster_info[:version] < Gem::Version.new('7.6'))
      end

      it 'memoizes the result' do
        allow(adapter).to receive(:cluster_settings).and_return({ 'indices.id_field_data.enabled' => true })

        adapter.access_id_fielddata?
        adapter.access_id_fielddata?

        expect(adapter).to have_received(:cluster_settings).once
      end
    end

    describe '#access_shard_doc?' do
      it 'is true from cluster version 7.12' do
        expect(adapter.access_shard_doc?).to be(adapter.cluster_info[:version] >= Gem::Version.new('7.12'))
      end
    end
  end
end
