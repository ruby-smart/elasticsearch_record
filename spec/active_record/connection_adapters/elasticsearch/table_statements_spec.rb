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

  # the *_tables methods are plain loops - they neither resolve nor filter a name on their own,
  # both is left to the singular statement they delegate to
  {
    open_tables:     :open_table,
    close_tables:    :close_table,
    refresh_tables:  :refresh_table,
    truncate_tables: :truncate_table
  }.each do |plural, singular|
    describe "##{plural}" do
      before { allow(adapter).to receive(singular) }

      it 'maps over every provided table' do
        adapter.public_send(plural, 'index-a', 'index-b')

        expect(adapter).to have_received(singular).with('index-a', decorate: nil)
        expect(adapter).to have_received(singular).with('index-b', decorate: nil)
      end

      it 'returns an empty array without any provided table' do
        expect(adapter.public_send(plural)).to eq([])
        expect(adapter).not_to have_received(singular)
      end

      # the singular statement owns the decoration, so the RAW flag is forwarded - resolving the
      # name here would decorate it a second time
      it 'forwards the decorate flag untouched' do
        adapter.public_send(plural, 'some-index', decorate: false)

        expect(adapter).to have_received(singular).with('some-index', decorate: false)
      end

      it 'forwards an explicit decorate: true' do
        adapter.public_send(plural, 'some-index', decorate: true)

        expect(adapter).to have_received(singular).with('some-index', decorate: true)
      end
    end
  end

  # only +#truncate_table+ guards the AR-internal indices - a truncate is a 'drop & create' in
  # elasticsearch and would wipe the migration state of the whole environment
  describe 'the internal table guard' do
    describe '#truncate_table' do
      before do
        allow(adapter).to receive(:create_table)
        allow(adapter).to receive(:table_schema).and_return({})
      end

      it 'raises for the schema migrations table' do
        expect { adapter.truncate_table('schema_migrations') }
          .to raise_error(ArgumentError, /Cannot truncate internal table 'schema_migrations'/)

        expect(adapter).not_to have_received(:create_table)
      end

      it 'raises for the internal metadata table' do
        expect { adapter.truncate_table('ar_internal_metadata') }
          .to raise_error(ArgumentError, /Cannot truncate internal table 'ar_internal_metadata'/)
      end

      it 'raises before resolving the schema of the table' do
        expect { adapter.truncate_table('schema_migrations') }.to raise_error(ArgumentError)

        expect(adapter).not_to have_received(:table_schema)
      end

      it 'passes any other table through' do
        expect { adapter.truncate_table('some-index') }.not_to raise_error

        expect(adapter).to have_received(:create_table).with('some-index', hash_including(force: true, decorate: false))
      end

      it 'aborts a #truncate_tables call on the first internal table' do
        expect { adapter.truncate_tables('some-index', 'schema_migrations', 'other-index') }
          .to raise_error(ArgumentError, /Cannot truncate internal table/)

        expect(adapter).to have_received(:create_table).with('some-index', any_args)
        expect(adapter).not_to have_received(:create_table).with('other-index', any_args)
      end

      # the check runs on the ALREADY resolved name and +_internal_table_names+ holds both forms -
      # a BASE name would otherwise never match the resolved one the schema migration provides
      context 'with a configured prefix & suffix' do
        subject(:adapter) do
          ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.new(
            ElasticsearchSpec::CONFIG.symbolize_keys.merge(table_name_prefix: 'pre_', table_name_suffix: '_suf'))
        end

        before do
          allow(adapter).to receive(:schema_migration)
                              .and_return(instance_double(ElasticsearchRecord::SchemaMigration, table_name: 'pre_schema_migrations_suf'))
        end

        it 'raises for the base name' do
          expect { adapter.truncate_table('schema_migrations') }
            .to raise_error(ArgumentError, /Cannot truncate internal table 'pre_schema_migrations_suf'/)
        end

        it 'raises for the already resolved name' do
          expect { adapter.truncate_table('pre_schema_migrations_suf') }
            .to raise_error(ArgumentError, /Cannot truncate internal table 'pre_schema_migrations_suf'/)
        end

        # +ActiveRecord::InternalMetadata+ resolves through +ActiveRecord::Base+, so it stays
        # undecorated while the schema migration does not - both forms have to be covered
        it 'raises for the undecorated internal metadata table' do
          expect { adapter.truncate_table('ar_internal_metadata', decorate: false) }
            .to raise_error(ArgumentError, /Cannot truncate internal table 'ar_internal_metadata'/)
        end

        it 'passes a literal name through with decorate: false' do
          allow(adapter).to receive(:create_table)
          allow(adapter).to receive(:table_schema).and_return({})

          expect { adapter.truncate_table('schema_migrations', decorate: false) }.not_to raise_error
        end
      end
    end

    # +ActiveRecord::SchemaMigration#drop_table+ & +ActiveRecord::InternalMetadata#drop_table+ both
    # call +connection.drop_table(table_name, if_exists: true)+ - a guard here would break that API
    describe '#drop_table' do
      before do
        allow(adapter).to receive(:api).and_return({})
        allow(adapter).to receive(:schema_cache)
                            .and_return(instance_double(ActiveRecord::ConnectionAdapters::BoundSchemaReflection, clear_data_source_cache!: nil))
      end

      %w[schema_migrations ar_internal_metadata].each do |internal|
        it "drops the internal '#{internal}' table" do
          expect { adapter.drop_table(internal, if_exists: true) }.not_to raise_error

          expect(adapter).to have_received(:api)
                               .with('indices.delete', { index: internal, ignore: 404 }, 'DROP TABLE')
        end
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

    # 'table_name_prefix:' without a value is a valid yml entry and resolves to nil - which blew up
    # the +start_with?+ check. Harmless while the method was opt-in, but it now runs on EVERY
    # table statement.
    context 'with a nil prefix & suffix' do
      subject(:adapter) do
        ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.new(
          ElasticsearchSpec::CONFIG.symbolize_keys.merge(table_name_prefix: nil, table_name_suffix: nil))
      end

      it 'does not raise' do
        expect { adapter._env_table_name('my-index') }.not_to raise_error
      end

      it 'returns the name unchanged' do
        expect(adapter._env_table_name('my-index')).to eq('my-index')
      end
    end
  end

  # Every table statement resolves its name(s) through +#_env_table_name+ by DEFAULT - so a
  # migration only ever names the base table. +decorate: false+ addresses an index literally.
  describe 'the decorate flag' do
    subject(:adapter) do
      ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.new(
        ElasticsearchSpec::CONFIG.symbolize_keys.merge(table_name_prefix: 'pre_', table_name_suffix: '_suf'))
    end

    # keeps these examples off the cluster - only the resolved index name is the subject here
    before do
      allow(adapter).to receive(:api).and_return({})
      allow(adapter).to receive(:schema_cache).and_return(instance_double(ActiveRecord::ConnectionAdapters::BoundSchemaReflection, clear_data_source_cache!: nil))
    end

    describe '#drop_table' do
      it 'decorates the table name by default' do
        adapter.drop_table('my-index')

        expect(adapter).to have_received(:api)
                             .with('indices.delete', hash_including(index: 'pre_my-index_suf'), 'DROP TABLE')
      end

      it 'keeps the table name with decorate: false' do
        adapter.drop_table('my-index', decorate: false)

        expect(adapter).to have_received(:api)
                             .with('indices.delete', hash_including(index: 'my-index'), 'DROP TABLE')
      end

      # THE case the flag exists for: the guard of +_env_table_name+ cannot tell a resolved name
      # apart from a base name that legitimately starts with the prefix
      it 'addresses a name that starts with the prefix literally' do
        adapter.drop_table('pre_tools', decorate: false)

        expect(adapter).to have_received(:api)
                             .with('indices.delete', hash_including(index: 'pre_tools'), 'DROP TABLE')
      end
    end

    # REGRESSION: +rename_table+ only forwarded the flag to the statements it calls - the
    # +schema_cache+ and the +cluster_health+ call in between address the index directly and were
    # left with the UNDECORATED name, so the health check waited for an index that does not exist
    describe '#rename_table' do
      before do
        allow(adapter).to receive(:clone_table)
        allow(adapter).to receive(:cluster_health)
        allow(adapter).to receive(:drop_table)
      end

      it 'resolves both names before waiting for the cluster health' do
        adapter.rename_table('my-index', 'my-target')

        expect(adapter).to have_received(:cluster_health)
                             .with(hash_including(index: 'pre_my-target_suf'))
      end

      it 'clears the schema cache of the resolved name' do
        adapter.rename_table('my-index', 'my-target')

        expect(adapter.schema_cache).to have_received(:clear_data_source_cache!).with('pre_my-index_suf')
      end

      # both names are resolved HERE, so the statements below must not decorate them again
      it 'hands the resolved names down with decorate: false' do
        adapter.rename_table('my-index', 'my-target')

        expect(adapter).to have_received(:clone_table).with('pre_my-index_suf', 'pre_my-target_suf', decorate: false)
        expect(adapter).to have_received(:drop_table).with('pre_my-index_suf', decorate: false)
      end

      it 'keeps both names with decorate: false' do
        adapter.rename_table('my-index', 'my-target', decorate: false)

        expect(adapter).to have_received(:clone_table).with('my-index', 'my-target', decorate: false)
        expect(adapter).to have_received(:cluster_health).with(hash_including(index: 'my-target'))
      end
    end

    describe '#refresh_table' do
      it 'decorates the table name by default' do
        adapter.refresh_table('my-index')

        expect(adapter).to have_received(:api)
                             .with('indices.refresh', { index: 'pre_my-index_suf' }, 'REFRESH TABLE')
      end

      it 'keeps the table name with decorate: false' do
        adapter.refresh_table('my-index', decorate: false)

        expect(adapter).to have_received(:api).with('indices.refresh', { index: 'my-index' }, 'REFRESH TABLE')
      end
    end

    describe '#open_table' do
      it 'decorates the table name by default' do
        adapter.open_table('my-index')

        expect(adapter).to have_received(:api).with('indices.open', { index: 'pre_my-index_suf' }, 'OPEN TABLE')
      end

      it 'keeps the table name with decorate: false' do
        adapter.open_table('my-index', decorate: false)

        expect(adapter).to have_received(:api).with('indices.open', { index: 'my-index' }, 'OPEN TABLE')
      end
    end

    describe '#close_table' do
      it 'decorates the table name by default' do
        adapter.close_table('my-index')

        expect(adapter).to have_received(:api).with('indices.close', { index: 'pre_my-index_suf' }, 'CLOSE TABLE')
      end
    end

    describe '#block_table' do
      it 'decorates the table name by default' do
        adapter.block_table('my-index')

        expect(adapter).to have_received(:api)
                             .with('indices.add_block', { index: 'pre_my-index_suf', block: :write }, 'BLOCK WRITE TABLE')
      end

      it 'keeps the table name with decorate: false' do
        adapter.block_table('my-index', :read, decorate: false)

        expect(adapter).to have_received(:api)
                             .with('indices.add_block', { index: 'my-index', block: :read }, 'BLOCK READ TABLE')
      end
    end

    # a statement with TWO names - both are decorated (or both left alone)
    describe '#reindex_table' do
      it 'decorates both table names by default' do
        adapter.reindex_table('source', 'target')

        expect(adapter).to have_received(:api).with(
          :reindex,
          { body: { source: { index: 'pre_source_suf' }, dest: { index: 'pre_target_suf' } } },
          'REINDEX TABLE')
      end

      it 'keeps both table names with decorate: false' do
        adapter.reindex_table('source', 'target', decorate: false)

        expect(adapter).to have_received(:api).with(
          :reindex,
          { body: { source: { index: 'source' }, dest: { index: 'target' } } },
          'REINDEX TABLE')
      end
    end

    # the flag reaches +change_table+ through +_exec_change_table_with+
    describe 'the mapping / setting / alias statements' do
      before { allow(adapter).to receive(:change_table) }

      # nil forwards the GLOBAL default - only an explicitly provided flag is passed through
      it 'forwards decorate: nil by default' do
        adapter.add_mapping('my-index', :name, :keyword)

        expect(adapter).to have_received(:change_table).with('my-index', recreate: false, decorate: nil)
      end

      it 'forwards a provided decorate: false' do
        adapter.add_mapping('my-index', :name, :keyword, decorate: false)

        expect(adapter).to have_received(:change_table).with('my-index', recreate: false, decorate: false)
      end

      it 'does not leak the flag into the mapping options' do
        adapter.change_setting('my-index', 'index.blocks.write', nil, decorate: false)

        expect(adapter).to have_received(:change_table).with('my-index', recreate: false, decorate: false)
      end
    end

    # the global kill-switch only provides the DEFAULT for a statement that was not given an
    # explicit +decorate:+ argument
    describe 'ElasticsearchRecord.decorate_table_names' do
      around do |example|
        ElasticsearchRecord.decorate_table_names = false
        example.run
      ensure
        ElasticsearchRecord.decorate_table_names = true
      end

      it 'defaults to true' do
        ElasticsearchRecord.decorate_table_names = true

        expect(ElasticsearchRecord.decorate_table_names).to be(true)
      end

      it 'stops the decoration of a statement without the flag' do
        adapter.refresh_table('my-index')

        expect(adapter).to have_received(:api).with('indices.refresh', { index: 'my-index' }, 'REFRESH TABLE')
      end

      it 'is still overruled by an explicit decorate: true' do
        adapter.refresh_table('my-index', decorate: true)

        expect(adapter).to have_received(:api).with('indices.refresh', { index: 'pre_my-index_suf' }, 'REFRESH TABLE')
      end

      # the plural statement forwards the RAW flag - the global default is resolved by the singular
      # one it delegates to, so the kill-switch reaches through
      it 'also stops the decoration of the *_tables statements' do
        adapter.refresh_tables('my-index')

        expect(adapter).to have_received(:api).with('indices.refresh', { index: 'my-index' }, 'REFRESH TABLE')
      end

      it 'reaches the statements behind _exec_change_table_with' do
        adapter.add_mapping('my-index', :name, :keyword)

        expect(adapter).to have_received(:api)
                             .with('indices.put_mapping', hash_including(index: 'my-index'), 'ADD MAPPING', any_args)
      end

      # +_env_table_name+ is the raw resolver - it stays unaffected, so existing migrations that
      # call it by hand keep working while the automatic decoration is off
      it 'does not disable the _env_table_name method itself' do
        expect(adapter._env_table_name('my-index')).to eq('pre_my-index_suf')
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
      # +rename_table+ used to sit in the +define_unsupported_method+ list while the real
      # implementation was defined AFTER it - this pins that the implemented one is in place.
      it 'is implemented (and not the unsupported placeholder)' do
        expect(adapter.method(:rename_table).parameters)
          .to eq([[:req, :table_name], [:req, :target_name], [:key, :timeout], [:key, :decorate], [:keyrest, :options]])
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

  # END-TO-END proof of the default decoration: a migration only ever names the BASE table and
  # every statement resolves it against the prefix / suffix of the connection config.
  #
  # SAFETY: the decorated name stays within +TestIndex::ALLOWED+, so it can never wipe a real index.
  context 'against a real index with a configured suffix', :elasticsearch do
    subject(:adapter) do
      ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.new(
        ElasticsearchSpec::CONFIG.symbolize_keys.merge(table_name_suffix: '_suffixed'))
    end

    # the name a migration would use ...
    let(:base_name) { TestIndex.name }

    # ... and the index it actually resolves to
    let(:decorated_name) { "#{TestIndex.name}_suffixed" }

    let(:target_name) { "#{TestIndex.name}-target" }

    # 0 replicas, so a clone can reach the 'green' state +#rename_table+ waits for on a single node
    let(:table_definition) do
      proc do |t|
        t.mapping :name, :keyword

        t.setting 'index.number_of_shards', '1'
        t.setting 'index.number_of_replicas', '0'
      end
    end

    after do
      [base_name, decorated_name, target_name, "#{target_name}_suffixed"].each { |name| TestIndex.drop!(name) }
      # the auto-generated backup names carry a timestamp - resolve & drop them
      ElasticsearchSpec.connection.tables.grep(/-snapshot-\d+\z/).each { |name| TestIndex.drop!(name) }
    end

    describe '#create_table' do
      it 'creates the decorated index from a base name' do
        adapter.create_table(base_name, force: true, &table_definition)

        expect(TestIndex.exists?(decorated_name)).to be(true)
      end

      it 'does not create the undecorated index' do
        adapter.create_table(base_name, force: true, &table_definition)

        expect(TestIndex.exists?(base_name)).to be(false)
      end

      it 'creates the literal index with decorate: false' do
        adapter.create_table(base_name, force: true, decorate: false) { |t| t.mapping :name, :keyword }

        expect(TestIndex.exists?(base_name)).to be(true)
        expect(TestIndex.exists?(decorated_name)).to be(false)
      end
    end

    context 'with an existing table' do
      before { adapter.create_table(base_name, force: true, &table_definition) }

      # the SCHEMA statements are deliberately NOT decorated - they are called by ActiveRecord &
      # the schema dumper with an already resolved index name
      describe '#table_exists?' do
        it 'is not decorated' do
          expect(adapter.table_exists?(decorated_name)).to be(true)
          expect(adapter.table_exists?(base_name)).to be(false)
        end
      end

      describe '#add_mapping' do
        it 'reaches the decorated index through the base name' do
          adapter.add_mapping(base_name, :added, :integer)

          expect(adapter.table_mappings(decorated_name)['properties']).to include('added')
        end
      end

      describe '#change_setting' do
        it 'reaches the decorated index through the base name' do
          adapter.change_setting(base_name, 'index.number_of_replicas', 0)

          expect(adapter.table_settings(decorated_name)['index.number_of_replicas']).to eq('0')
        end
      end

      describe '#refresh_table' do
        it 'reaches the decorated index through the base name' do
          expect(adapter.refresh_table(base_name)).to be(true)
        end
      end

      describe '#rename_table' do
        it 'decorates BOTH names' do
          adapter.rename_table(base_name, target_name)

          expect(TestIndex.exists?("#{target_name}_suffixed")).to be(true)
          expect(TestIndex.exists?(decorated_name)).to be(false)
        end
      end

      describe '#backup_table' do
        # REGRESSION: the auto-generated name is built from the ALREADY resolved name - building it
        # from the raw argument would append the suffix BEHIND the '-snapshot-' part
        it 'builds the auto-generated target from the decorated name' do
          expect(adapter.backup_table(base_name)).to match(/\A#{Regexp.escape(decorated_name)}-snapshot-\d+\z/)
        end

        it 'decorates a provided target' do
          adapter.backup_table(base_name, to: target_name)

          expect(TestIndex.exists?("#{target_name}_suffixed")).to be(true)
        end
      end

      describe '#restore_table' do
        it 'restores the decorated index from a decorated backup' do
          adapter.backup_table(base_name, to: target_name)
          adapter.drop_table(base_name)
          adapter.restore_table(base_name, from: target_name)

          expect(TestIndex.exists?(decorated_name)).to be(true)
        end
      end

      describe '#truncate_table' do
        it 'keeps the decorated index (and its mappings) in place' do
          adapter.truncate_table(base_name)

          expect(TestIndex.exists?(decorated_name)).to be(true)
          expect(adapter.table_mappings(decorated_name)['properties']).to include('name')
        end
      end

      describe '#drop_table' do
        it 'drops the decorated index through the base name' do
          adapter.drop_table(base_name)

          expect(TestIndex.exists?(decorated_name)).to be(false)
        end
      end
    end
  end
end
