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

  # recaps a table name with the prefix & suffix of the CONNECTION config (not of ActiveRecord::Base)
  describe '#_env_table_name' do
    it 'returns the name unchanged without a configured prefix & suffix' do
      expect(adapter._env_table_name('my-index')).to eq('my-index')
    end

    it 'casts a provided Symbol' do
      expect(adapter._env_table_name(:my_index)).to eq('my_index')
    end

    context 'with a configured prefix & suffix' do
      subject(:adapter) do
        ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.new(
          ElasticsearchSpec::CONFIG.symbolize_keys.merge(table_name_prefix: 'pre_', table_name_suffix: '_suf'))
      end

      it 'wraps the name' do
        expect(adapter._env_table_name('my-index')).to eq('pre_my-index_suf')
      end

      # a name that is already recapped must not be wrapped twice - this is what makes the method
      # idempotent & safe to call on an already resolved index name
      it 'does not add an already present prefix' do
        expect(adapter._env_table_name('pre_my-index')).to eq('pre_my-index_suf')
      end

      it 'does not add an already present suffix' do
        expect(adapter._env_table_name('my-index_suf')).to eq('pre_my-index_suf')
      end

      it 'is idempotent' do
        expect(adapter._env_table_name(adapter._env_table_name('my-index'))).to eq('pre_my-index_suf')
      end

      it 'returns an unfrozen String' do
        expect(adapter._env_table_name('my-index')).not_to be_frozen
      end
    end
  end

  # PLEASE NOTE: the +:elasticsearch+ tag skips these examples through a +before(:each)+ hook
  # (see spec_helper.rb) - so the index setup must NOT run in a +before(:all)+, which would
  # execute before that hook and blow up instead of skipping.
  context 'against a real index', :elasticsearch do
    subject(:adapter) { ElasticsearchSpec.connection }

    let(:index_name) { TestIndex.name }

    # every additional index this context may create - all of them stay inside the test namespace
    let(:target_name) { "#{TestIndex.name}-target" }
    let(:backup_name) { "#{TestIndex.name}-backup" }

    before do
      TestIndex.create!
      adapter.add_mapping(index_name, :extra, :keyword)
      adapter.api(:bulk, {
        index:   index_name,
        body:    [{ index: { _id: '1', data: { name: 'alpha', count: 1 } } },
                  { index: { _id: '2', data: { name: 'beta', count: 2 } } }],
        refresh: true
      }, 'SPEC SETUP')
    end

    after do
      [index_name, target_name, backup_name].each { |name| TestIndex.drop!(name) }
      # the auto-generated backup names carry a timestamp - resolve & drop them
      adapter.tables.grep(/\A#{Regexp.escape(index_name)}-snapshot-/).each { |name| TestIndex.drop!(name) }
    end

    ###################
    # BACKUP  RESTORE #
    ###################

    describe '#backup_table' do
      it 'clones the table into an auto-generated target' do
        backup = adapter.backup_table(index_name)

        expect(backup).to match(/\A#{Regexp.escape(index_name)}-snapshot-\d+\z/)
        expect(adapter.table_exists?(backup)).to be(true)
      end

      it 'clones into a provided target' do
        expect(adapter.backup_table(index_name, to: backup_name)).to eq(backup_name)
        expect(adapter.table_exists?(backup_name)).to be(true)
      end

      # the backup is closed, so it can neither be read nor written by accident
      it 'closes the backup by default' do
        adapter.backup_table(index_name, to: backup_name)

        expect(adapter.table_state(backup_name)[:status]).to eq('close')
      end

      it 'keeps the backup open with close: false' do
        adapter.backup_table(index_name, to: backup_name, close: false)

        expect(adapter.table_state(backup_name)[:status]).to eq('open')
      end

      it 'carries the documents over' do
        adapter.backup_table(index_name, to: backup_name, close: false)
        adapter.refresh_table(backup_name)

        expect(adapter.table_state(backup_name)[:docs_count]).to eq('2')
      end

      it 'keeps the source table untouched' do
        adapter.backup_table(index_name, to: backup_name)

        expect(adapter.table_exists?(index_name)).to be(true)
      end

      it 'raises for an already existing target' do
        adapter.backup_table(index_name, to: backup_name)

        expect { adapter.backup_table(index_name, to: backup_name) }
          .to raise_error(ArgumentError, /unable to backup '#{index_name}' to already existing target/)
      end
    end

    describe '#restore_table' do
      before { adapter.backup_table(index_name, to: backup_name) }

      it 'restores the table from the backup' do
        adapter.drop_table(index_name)
        adapter.restore_table(index_name, from: backup_name)

        expect(adapter.table_exists?(index_name)).to be(true)
        expect(adapter.table_state(index_name)[:docs_count]).to eq('2')
      end

      # an existing table is dropped first - the restore always wins
      it 'overwrites an existing table' do
        adapter.restore_table(index_name, from: backup_name)

        expect(adapter.table_exists?(index_name)).to be(true)
      end

      it 'keeps the backup by default' do
        adapter.restore_table(index_name, from: backup_name)

        expect(adapter.table_exists?(backup_name)).to be(true)
      end

      # the backup keeps its (closed) state - only the restored table is touched
      it 'leaves the backup closed' do
        adapter.restore_table(index_name, from: backup_name)

        expect(adapter.table_state(backup_name)[:status]).to eq('close')
      end

      # PLEASE NOTE: a clone is ALWAYS created open - even from a closed source. There is
      # therefore no +open+ flag; the restored table never needs to be opened.
      it 'leaves the restored table open' do
        adapter.restore_table(index_name, from: backup_name)

        expect(adapter.table_state(index_name)[:status]).to eq('open')
      end

      it 'raises for a missing target' do
        expect { adapter.restore_table(index_name, from: 'nope-does-not-exist') }
          .to raise_error(ArgumentError, /unable to restore from missing target/)
      end

      # THE reason the +unblock+ flag exists: the restore runs through a clone, which inherits the
      # 'write'-block that is required to clone at all - so the restored table would stay read-only.
      # see @ ActiveRecord::ConnectionAdapters::Elasticsearch::CloneTableDefinition#_before_exec
      describe 'the unblock flag' do
        def blocks
          adapter.table_settings(index_name).select { |key, _value| key.include?('blocks') }
        end

        # a DOCUMENT write - that is what 'index.blocks.write' actually stops
        def write_document
          adapter.api(:bulk, {
            index:   index_name,
            body:    [{ index: { _id: 'after-restore', data: { name: 'written' } } }],
            refresh: true
          }, 'SPEC WRITE')
        end

        it 'releases the inherited write block' do
          adapter.restore_table(index_name, from: backup_name)

          expect(blocks).to eq({})
        end

        # PLEASE NOTE: the block only stops DOCUMENT writes - a mapping change still passes
        it 'makes the restored table writable' do
          adapter.restore_table(index_name, from: backup_name)

          expect(write_document['errors']).to be(false)
        end

        it 'keeps the block with unblock: false' do
          adapter.restore_table(index_name, from: backup_name, unblock: false)

          expect(blocks).to eq({ 'index.blocks.write' => 'true' })
        end

        it 'leaves the table read-only with unblock: false' do
          adapter.restore_table(index_name, from: backup_name, unblock: false)

          response = write_document

          expect(response['errors']).to be(true)
          expect(response['items'][0]['index']['error']['type']).to eq('cluster_block_exception')
        end

        # the former +open+ flag is gone - it could never influence the state of the restored table
        it 'no longer accepts an open flag' do
          expect { adapter.restore_table(index_name, from: backup_name, open: true) }
            .to raise_error(ArgumentError, /unknown keyword: :open/)
        end
      end

      # with +drop_backup+ the backup is RENAMED into place - which removes it
      context 'with drop_backup' do
        it 'restores the table and removes the backup' do
          adapter.restore_table(index_name, from: backup_name, drop_backup: true)

          expect(adapter.table_exists?(index_name)).to be(true)
          expect(adapter.table_exists?(backup_name)).to be(false)
        end

        it 'does not raise' do
          expect { adapter.restore_table(index_name, from: backup_name, drop_backup: true) }
            .not_to raise_error
        end

        it 'carries the documents over' do
          adapter.restore_table(index_name, from: backup_name, drop_backup: true)
          adapter.refresh_table(index_name)

          expect(adapter.table_state(index_name)[:docs_count]).to eq('2')
        end

        # the rename strategy inherits the very same block
        it 'also releases the inherited write block' do
          adapter.restore_table(index_name, from: backup_name, drop_backup: true)

          expect(adapter.table_settings(index_name).select { |key, _| key.include?('blocks') }).to eq({})
        end
      end
    end

    ####################
    # RENAME & REINDEX #
    ####################

    describe '#rename_table' do
      # PLEASE NOTE: +rename_table+ is part of the +define_unsupported_method+ list, but the real
      # implementation is defined AFTER it - so it overwrites the raising one.
      it 'is implemented (and not the unsupported placeholder)' do
        expect(adapter.method(:rename_table).parameters)
          .to eq([[:req, :table_name], [:req, :target_name], [:key, :timeout], [:keyrest, :options]])
      end

      it 'moves the table to the target name' do
        adapter.rename_table(index_name, target_name)

        expect(adapter.table_exists?(index_name)).to be(false)
        expect(adapter.table_exists?(target_name)).to be(true)
      end

      it 'carries the documents over' do
        adapter.rename_table(index_name, target_name)

        expect(adapter.table_state(target_name)[:docs_count]).to eq('2')
      end

      it 'carries the mappings over' do
        adapter.rename_table(index_name, target_name)

        expect(adapter.table_mappings(target_name)['properties'].keys).to include('extra')
      end

      it 'accepts a custom timeout' do
        expect { adapter.rename_table(index_name, target_name, timeout: '10s') }.not_to raise_error
      end
    end

    describe '#reindex_table' do
      before do
        adapter.create_table(target_name, force: true) do |t|
          t.mapping :name, :keyword
          t.mapping :count, :integer
        end
      end

      it 'copies the documents into the target' do
        stats = adapter.reindex_table(index_name, target_name)

        expect(stats['total']).to eq(2)
        expect(stats['created']).to eq(2)
        expect(stats['failures']).to eq([])
      end

      it 'makes the documents resolvable in the target' do
        adapter.reindex_table(index_name, target_name)
        adapter.refresh_table(target_name)

        expect(adapter.table_state(target_name)[:docs_count]).to eq('2')
      end

      it 'keeps the source untouched' do
        adapter.reindex_table(index_name, target_name)

        expect(adapter.table_state(index_name)[:docs_count]).to eq('2')
      end

      # everything beyond source & dest is merged into the API arguments
      it 'merges provided options into the api arguments' do
        expect(adapter.reindex_table(index_name, target_name, refresh: true)['total']).to eq(2)
      end
    end

    ############
    # MAPPINGS #
    ############

    describe 'the mapping statements' do
      def properties
        adapter.table_mappings(index_name)['properties']
      end

      describe '#add_mapping' do
        it 'adds a new mapping' do
          adapter.add_mapping(index_name, :added, :integer)

          expect(properties['added']).to eq({ 'type' => 'integer' })
        end

        it 'forwards additional options' do
          adapter.add_mapping(index_name, :added, :keyword, meta: { unit: 'ms' })

          expect(properties['added']).to eq({ 'type' => 'keyword', 'meta' => { 'unit' => 'ms' } })
        end

        it 'is aliased as #add_column' do
          adapter.add_column(index_name, :added, :boolean)

          expect(properties['added']).to eq({ 'type' => 'boolean' })
        end
      end

      describe '#change_mapping' do
        # Elasticsearch cannot change an existing mapping - the index has to be recreated
        it 'raises without the recreate flag' do
          expect { adapter.change_mapping(index_name, :extra, :text) }
            .to raise_error(ArgumentError, /without the 'recreate: true' flag/)
        end

        it 'changes the mapping with the recreate flag' do
          adapter.change_mapping(index_name, :extra, :text, recreate: true)

          expect(properties['extra']['type']).to eq('text')
        end

        it 'is aliased as #change_column' do
          adapter.change_column(index_name, :extra, :text, recreate: true)

          expect(properties['extra']['type']).to eq('text')
        end
      end

      describe '#remove_mapping' do
        it 'raises without the recreate flag' do
          expect { adapter.remove_mapping(index_name, :extra) }
            .to raise_error(ArgumentError, /without the 'recreate: true' flag/)
        end

        it 'removes the mapping with the recreate flag' do
          adapter.remove_mapping(index_name, :extra, recreate: true)

          expect(properties.keys).not_to include('extra')
        end

        it 'is aliased as #remove_column' do
          adapter.remove_column(index_name, :extra, recreate: true)

          expect(properties.keys).not_to include('extra')
        end
      end

      describe '#change_mapping_meta' do
        # the 'meta' of a mapping IS changeable without a recreate
        it 'merges into the mapping meta' do
          adapter.change_mapping_meta(index_name, :extra, comment: 'hello')

          expect(properties['extra']).to eq({ 'type' => 'keyword', 'meta' => { 'comment' => 'hello' } })
        end

        it 'keeps the existing type' do
          adapter.change_mapping_meta(index_name, :extra, comment: 'hello')

          expect(properties['extra']['type']).to eq('keyword')
        end

        it 'raises for an unknown mapping' do
          expect { adapter.change_mapping_meta(index_name, :nope, comment: 'x') }
            .to raise_error(ArgumentError, /unknown mapping 'nope'/)
        end
      end

      describe '#change_mapping_attributes' do
        it 'merges the provided attributes into the mapping' do
          adapter.change_mapping_attributes(index_name, :extra, meta: { unit: 'ms' })

          expect(properties['extra']).to eq({ 'type' => 'keyword', 'meta' => { 'unit' => 'ms' } })
        end

        # IMPORTANT: the type has to survive - it is resolved from the CURRENT mapping, whose Hash
        # is String-keyed. A symbol access would resolve nil and fall back to :object / :nested,
        # which Elasticsearch then rejects for every real mapping parameter.
        it 'keeps the existing type' do
          adapter.change_mapping_attributes(index_name, :extra, meta: { unit: 'ms' })

          expect(properties['extra']['type']).to eq('keyword')
        end

        it 'works for a mapping of the initial schema' do
          adapter.change_mapping_attributes(index_name, :name, meta: { unit: 'ms' })

          expect(properties['name']['type']).to eq('keyword')
        end

        it 'does nothing for an unknown mapping with the if_exists flag' do
          expect { adapter.change_mapping_attributes(index_name, :nope, if_exists: true, meta: { a: 'b' }) }
            .not_to raise_error
        end

        it 'raises for an unknown mapping without the flag' do
          expect { adapter.change_mapping_attributes(index_name, :nope, meta: { a: 'b' }) }
            .to raise_error(ArgumentError, /unknown mapping 'nope'/)
        end

        # a mapping flagged as primary_key additionally writes the index +_meta+
        context 'with a primary_key attribute' do
          it 'records the mapping as primary_key meta' do
            adapter.change_mapping_attributes(index_name, :extra, primary_key: true)

            expect(adapter.table_metas(index_name)).to eq({ 'primary_key' => 'extra' })
          end

          it 'makes it the resolved primary_key' do
            adapter.change_mapping_attributes(index_name, :extra, primary_key: true)

            expect(adapter.primary_keys(index_name)).to eq(['extra'])
          end

          it 'keeps the mapping itself untouched' do
            adapter.change_mapping_attributes(index_name, :extra, primary_key: true)

            expect(properties['extra']).to eq({ 'type' => 'keyword' })
          end

          it 'also records a provided auto_increment' do
            adapter.change_mapping_attributes(index_name, :extra, primary_key: true, auto_increment: 5)

            expect(adapter.table_metas(index_name)).to eq({ 'primary_key' => 'extra', 'auto_increment' => 5 })
          end
        end
      end

      describe '#change_meta' do
        it 'sets an index meta' do
          adapter.change_meta(index_name, :kind, 'demo')

          expect(adapter.table_metas(index_name)).to eq({ 'kind' => 'demo' })
        end

        it 'overwrites an existing meta' do
          adapter.change_meta(index_name, :kind, 'demo')
          adapter.change_meta(index_name, :kind, 'other')

          expect(adapter.table_metas(index_name)).to eq({ 'kind' => 'other' })
        end

        it 'keeps the other metas' do
          adapter.change_meta(index_name, :kind, 'demo')
          adapter.change_meta(index_name, :owner, 'me')

          expect(adapter.table_metas(index_name)).to eq({ 'kind' => 'demo', 'owner' => 'me' })
        end
      end

      describe '#remove_meta' do
        before { adapter.change_meta(index_name, :kind, 'demo') }

        it 'removes the meta' do
          adapter.remove_meta(index_name, :kind)

          expect(adapter.table_metas(index_name)).to eq({})
        end

        it 'keeps the other metas' do
          adapter.change_meta(index_name, :owner, 'me')
          adapter.remove_meta(index_name, :kind)

          expect(adapter.table_metas(index_name)).to eq({ 'owner' => 'me' })
        end
      end
    end

    ############
    # SETTINGS #
    ############

    describe 'the setting statements' do
      def settings
        adapter.table_settings(index_name)
      end

      describe '#add_setting' do
        it 'adds a dynamic setting' do
          adapter.add_setting(index_name, 'index.refresh_interval', '5s')

          expect(settings['index.refresh_interval']).to eq('5s')
        end

        it 'accepts a non-String value' do
          adapter.add_setting(index_name, 'index.number_of_replicas', 2)

          expect(settings['index.number_of_replicas']).to eq('2')
        end

        it 'raises for an unknown setting' do
          expect { adapter.add_setting(index_name, 'index.nope_setting', 1) }
            .to raise_error(ActiveRecord::StatementInvalid)
        end
      end

      describe '#change_setting' do
        before { adapter.add_setting(index_name, 'index.refresh_interval', '5s') }

        it 'overwrites the existing value' do
          adapter.change_setting(index_name, 'index.refresh_interval', '10s')

          expect(settings['index.refresh_interval']).to eq('10s')
        end

        # a nil value resets the setting to its default - this is how a block is released
        it 'removes the setting for a nil value' do
          adapter.change_setting(index_name, 'index.refresh_interval', nil)

          expect(settings).not_to have_key('index.refresh_interval')
        end
      end

      describe '#remove_setting' do
        before { adapter.add_setting(index_name, 'index.refresh_interval', '5s') }

        it 'resets the setting to its default' do
          adapter.remove_setting(index_name, 'index.refresh_interval')

          expect(settings).not_to have_key('index.refresh_interval')
        end

        it 'keeps the other settings' do
          adapter.remove_setting(index_name, 'index.refresh_interval')

          expect(settings['index.number_of_shards']).to be_present
        end
      end
    end

    #####################
    # BLOCK  &  UNBLOCK #
    #####################

    describe '#unblock_table' do
      def blocks
        adapter.table_settings(index_name).select { |key, _value| key.include?('blocks') }
      end

      it 'releases a named block' do
        adapter.block_table(index_name, :write)
        expect(blocks).to eq({ 'index.blocks.write' => 'true' })

        adapter.unblock_table(index_name, :write)

        expect(blocks).to eq({})
      end

      # without a name EVERY block is released in a single change_table call
      it 'releases every block without a provided name' do
        adapter.block_table(index_name, :write)
        adapter.block_table(index_name, :read)
        expect(blocks.keys).to match_array(%w[index.blocks.write index.blocks.read])

        adapter.unblock_table(index_name)

        expect(blocks).to eq({})
      end

      it 'does not raise without any existing block' do
        expect { adapter.unblock_table(index_name) }.not_to raise_error
        expect(blocks).to eq({})
      end

      it 'makes the table writable again' do
        adapter.block_table(index_name, :write)
        adapter.unblock_table(index_name)

        expect { adapter.add_mapping(index_name, :after_unblock, :keyword) }.not_to raise_error
      end
    end

    ##############
    # CLONE      #
    ##############

    describe '#clone_table' do
      it 'creates the target index' do
        adapter.clone_table(index_name, target_name)

        expect(adapter.table_exists?(target_name)).to be(true)
      end

      it 'carries the documents & mappings over' do
        adapter.clone_table(index_name, target_name)

        expect(adapter.table_state(target_name)[:docs_count]).to eq('2')
        expect(adapter.table_mappings(target_name)['properties'].keys).to include('extra')
      end

      it 'keeps the source table' do
        adapter.clone_table(index_name, target_name)

        expect(adapter.table_exists?(index_name)).to be(true)
      end

      # the source is write-blocked for the clone - and released again afterwards
      it 'releases the write block on the source afterwards' do
        adapter.clone_table(index_name, target_name)

        expect(adapter.table_settings(index_name).select { |key, _| key.include?('blocks') }).to eq({})
      end

      # PLEASE NOTE: a clone is ALWAYS created open - even from a closed source
      it 'creates an open target from a closed source' do
        adapter.close_table(index_name)
        adapter.clone_table(index_name, target_name)

        expect(adapter.table_state(target_name)[:status]).to eq('open')
      ensure
        adapter.open_table(index_name)
      end

      it 'yields the definition to a provided block' do
        yielded = nil

        adapter.clone_table(index_name, target_name) { |definition| yielded = definition }

        expect(yielded).to be_a(ActiveRecord::ConnectionAdapters::Elasticsearch::CloneTableDefinition)
      end

      it 'applies the settings assigned within the block' do
        adapter.clone_table(index_name, target_name) do |definition|
          definition.setting('index.number_of_replicas', 2, force: true)
        end

        expect(adapter.table_settings(target_name)['index.number_of_replicas']).to eq('2')
      end
    end

    ###########
    # ALIASES #
    ###########

    describe 'the alias statements' do
      def aliases
        adapter.table_aliases(index_name)
      end

      describe '#add_alias' do
        it 'adds the alias' do
          adapter.add_alias(index_name, 'my-alias')

          expect(aliases.keys).to eq(['my-alias'])
        end

        it 'stores the provided attributes' do
          adapter.add_alias(index_name, 'my-alias', routing: '1')

          expect(aliases['my-alias']).to eq({ 'index_routing' => '1', 'search_routing' => '1' })
        end

        it 'adds multiple aliases' do
          adapter.add_alias(index_name, 'alias-a')
          adapter.add_alias(index_name, 'alias-b')

          expect(aliases.keys).to match_array(%w[alias-a alias-b])
        end

        it 'makes the alias resolvable' do
          adapter.add_alias(index_name, 'my-alias')

          expect(adapter.alias_exists?(index_name, 'my-alias')).to be(true)
        end
      end

      describe '#change_alias' do
        before { adapter.add_alias(index_name, 'my-alias', routing: '1') }

        it 'overwrites the attributes' do
          adapter.change_alias(index_name, 'my-alias', routing: '2')

          expect(aliases['my-alias']).to eq({ 'index_routing' => '2', 'search_routing' => '2' })
        end

        it 'keeps the alias name' do
          adapter.change_alias(index_name, 'my-alias', routing: '2')

          expect(aliases.keys).to eq(['my-alias'])
        end
      end

      describe '#remove_alias' do
        before do
          adapter.add_alias(index_name, 'alias-a')
          adapter.add_alias(index_name, 'alias-b')
        end

        it 'removes the provided alias' do
          adapter.remove_alias(index_name, 'alias-a')

          expect(aliases.keys).to eq(['alias-b'])
        end

        it 'removes the last alias' do
          adapter.remove_alias(index_name, 'alias-a')
          adapter.remove_alias(index_name, 'alias-b')

          expect(aliases).to eq({})
        end
      end
    end
  end
end
