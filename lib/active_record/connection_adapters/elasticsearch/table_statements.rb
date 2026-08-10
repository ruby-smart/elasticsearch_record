# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      # extend adapter with table-related statements
      #
      # == Table name decoration
      #
      # Every statement below resolves its provided table name(s) through +#_env_table_name+, which
      # recaps them with the +table_name_prefix+ & +table_name_suffix+ of the connection config.
      # This happens by *default* - so a migration only ever has to name the *base* table (index):
      #
      #   create_table 'settings'   # => creates 'settings-dev' on a '-dev' suffixed connection
      #
      # Provide +decorate: false+ to address an index by its *literal* name instead. This is
      # required for names that are already resolved and for base names that happen to start with
      # the prefix (or end with the suffix), which +#_env_table_name+ cannot tell apart:
      #
      #   drop_table 'settings-pro', decorate: false
      #
      # The default of a NOT explicitly provided +decorate:+ argument is resolved from
      # +ElasticsearchRecord.decorate_table_names+ - setting it to false restores the former,
      # opt-in behaviour, where the decoration had to be applied by hand through +#_env_table_name+.
      # A single statement can still opt in or out on its own.
      #
      # PLEASE NOTE: the decoration only applies to table (index) names - +alias+, +mapping+,
      # +setting+ & +meta+ names are never touched.
      #
      # == Internal tables
      #
      # +schema_migrations+ & +ar_internal_metadata+ carry the migration state of the connection.
      # Only +#truncate_table+ guards them - it raises instead of wiping the state of a whole
      # environment, which in Elasticsearch means a +drop+ & +create+ of the index.
      #
      # Every other statement passes them through on purpose. +#drop_table+ especially MUST stay
      # open: ActiveRecord resets both tables through it
      # (+ActiveRecord::SchemaMigration#drop_table+ & +ActiveRecord::InternalMetadata#drop_table+
      # both call +connection.drop_table(table_name, if_exists: true)+), so a guard there would
      # break that API without an escape hatch.
      module TableStatements
        extend ActiveSupport::Concern

        included do
          # ORIGINAL methods untouched:
          #
          # SUPPORTED but not used:
          # -
          #
          # UNSUPPORTED methods that will be ignored:
          # - native_database_types
          # - table_options
          # - table_comment
          # - table_alias_for
          #
          # UNSUPPORTED methods that will fail:
          # - create_join_table
          # - drop_join_table
          # - create_alter_table
          # - change_column_default
          # - change_column_null
          # - rename_column

          define_unsupported_method :create_join_table, :drop_join_table, :create_alter_table,
                                    :change_column_default, :change_column_null, :rename_column

          # Opens a closed index.
          # @param [String] table_name
          # @param [Boolean] decorate - resolve the table name with the configured prefix & suffix (default: +ElasticsearchRecord.decorate_table_names+)
          # @return [Boolean] acknowledged status
          def open_table(table_name, decorate: nil)
            table_name = _decorate_table_name(table_name, decorate: decorate)

            # IMPORTANT: Clears out internal caches for the *table_name*
            schema_cache.clear_data_source_cache!(table_name)

            # call the API
            api('indices.open', { index: table_name }, 'OPEN TABLE').dig('acknowledged')
          end

          # Opens closed indices.
          # @param [Array] table_names
          # @param [Boolean] decorate - resolve the table names with the configured prefix & suffix (default: +ElasticsearchRecord.decorate_table_names+)
          # @return [Array] acknowledged status for each provided table
          def open_tables(*table_names, decorate: nil)
            table_names.map { |table_name| open_table(table_name, decorate: decorate) }
          end

          # Closes an index.
          # @param [String] table_name
          # @param [Boolean] decorate - resolve the table name with the configured prefix & suffix (default: +ElasticsearchRecord.decorate_table_names+)
          # @return [Boolean] acknowledged status
          def close_table(table_name, decorate: nil)
            table_name = _decorate_table_name(table_name, decorate: decorate)

            # IMPORTANT: Clears out internal caches for the *table_name*
            schema_cache.clear_data_source_cache!(table_name)

            # call the API
            api('indices.close', { index: table_name }, 'CLOSE TABLE').dig('acknowledged')
          end

          # Closes indices by provided names.
          # @param [Array] table_names
          # @param [Boolean] decorate - resolve the table names with the configured prefix & suffix (default: +ElasticsearchRecord.decorate_table_names+)
          # @return [Array] acknowledged status for each provided table
          def close_tables(*table_names, decorate: nil)
            table_names.map { |table_name| close_table(table_name, decorate: decorate) }
          end

          # refresh an index.
          # A refresh makes recent operations performed on one or more indices available for search.
          # raises an exception if the index could not be found.
          #
          # @param [String] table_name
          # @param [Boolean] decorate - resolve the table name with the configured prefix & suffix (default: +ElasticsearchRecord.decorate_table_names+)
          # @return [Boolean] result state (returns false if refreshing failed)
          def refresh_table(table_name, decorate: nil)
            table_name = _decorate_table_name(table_name, decorate: decorate)

            # call the API
            api('indices.refresh', { index: table_name }, 'REFRESH TABLE').dig('_shards', 'failed') == 0
          end

          # refresh indices by provided names.
          # @param [Array] table_names
          # @param [Boolean] decorate - resolve the table names with the configured prefix & suffix (default: +ElasticsearchRecord.decorate_table_names+)
          # @return [Array] result state (returns false if refreshing failed)
          def refresh_tables(*table_names, decorate: nil)
            table_names.map { |table_name| refresh_table(table_name, decorate: decorate) }
          end

          # truncates index by provided name.
          # HINT: Elasticsearch does not have a +truncate+ concept:
          # - so we have to store the current index' schema
          # - drop the index
          # - and create it again
          #
          # PLEASE NOTE: an AR-internal index (+schema_migrations+ / +ar_internal_metadata+) raises
          # instead - a truncate would drop the migration state of the whole environment. The check
          # runs on the ALREADY resolved name and +#_internal_table_names+ holds both forms, so
          # neither a base nor a resolved name slips through.
          #
          # @param [String] table_name
          # @param [Boolean] decorate - resolve the table name with the configured prefix & suffix (default: +ElasticsearchRecord.decorate_table_names+)
          # @raise [ArgumentError] if the resolved name is an AR-internal index
          # @return [Boolean] acknowledged status
          def truncate_table(table_name, decorate: nil)
            table_name = _decorate_table_name(table_name, decorate: decorate)

            # ensure the provided *table_name* is NOT an internal table_name
            raise ArgumentError, "Cannot truncate internal table '#{table_name}'!" if _internal_table_names.include?(table_name)

            # force: automatically drops an existing index
            create_table(table_name, force: true, decorate: false, **table_schema(table_name))
          end

          alias :truncate :truncate_table

          # truncate indices by provided names.
          # PLEASE NOTE: a single AR-internal index raises through +#truncate_table+ and aborts the
          # whole call - the tables before it are already truncated at that point.
          # @param [Array] table_names
          # @param [Boolean] decorate - resolve the table names with the configured prefix & suffix (default: +ElasticsearchRecord.decorate_table_names+)
          # @raise [ArgumentError] if one of the resolved names is an AR-internal index
          # @return [Array] acknowledged status for each provided table
          def truncate_tables(*table_names, decorate: nil)
            table_names.map { |table_name| truncate_table(table_name, decorate: decorate) }
          end

          # drops an index
          # [<tt>:if_exists</tt>]
          #   Set to +true+ to only drop the table if it exists.
          #   Defaults to false.
          #
          # PLEASE NOTE: unlike +#truncate_table+ this does NOT guard the AR-internal indices -
          # ActiveRecord resets them through exactly this statement
          # (+ActiveRecord::SchemaMigration#drop_table+ & +ActiveRecord::InternalMetadata#drop_table+
          # both call +connection.drop_table(table_name, if_exists: true)+).
          #
          # @param [String] table_name
          # @param [Boolean] if_exists
          # @param [Boolean] decorate - resolve the table name with the configured prefix & suffix (default: +ElasticsearchRecord.decorate_table_names+)
          # @return [Boolean] acknowledged status
          def drop_table(table_name, if_exists: false, decorate: nil, **)
            table_name = _decorate_table_name(table_name, decorate: decorate)

            # IMPORTANT: Clears out internal caches for the *table_name*
            schema_cache.clear_data_source_cache!(table_name)

            # call the API
            api('indices.delete', { index: table_name, ignore: (if_exists ? 404 : nil) }, 'DROP TABLE').dig('acknowledged')
          end

          # blocks access to the provided table (index) and +block+ name.
          # @param [String] table_name
          # @param [Symbol] block_name The block to add (one of :read, :write, :read_only or :metadata)
          # @param [Boolean] decorate - resolve the table name with the configured prefix & suffix (default: +ElasticsearchRecord.decorate_table_names+)
          # @return [Boolean] acknowledged status
          def block_table(table_name, block_name = :write, decorate: nil)
            table_name = _decorate_table_name(table_name, decorate: decorate)

            api('indices.add_block', { index: table_name, block: block_name }, "BLOCK #{block_name.to_s.upcase} TABLE").dig('acknowledged')
          end

          # unblocks access to the provided table (index) and +block+ name.
          # provide a nil-value to unblock all blocks, otherwise provide the blocked name.
          # @param [String] table_name
          # @param [Symbol] block_name The block to add (one of :read, :write, :read_only or :metadata)
          # @param [Boolean] decorate - resolve the table name with the configured prefix & suffix (default: +ElasticsearchRecord.decorate_table_names+)
          # @return [Boolean] acknowledged status
          def unblock_table(table_name, block_name = nil, decorate: nil)
            if block_name.nil?
              change_table(table_name, decorate: decorate) do |t|
                t.change_setting('index.blocks.read', nil)
                t.change_setting('index.blocks.write', nil)
                t.change_setting('index.blocks.read_only', nil)
                t.change_setting('index.blocks.metadata', nil)
              end
            else
              change_setting(table_name, "index.blocks.#{block_name}", nil, decorate: decorate)
            end
          end

          # clones an entire table (index) with its docs to the provided +target_name+.
          # During cloning, the table will be automatically 'write'-blocked.
          # @param [String] table_name
          # @param [String] target_name
          # @param [Boolean] decorate - resolve both table names with the configured prefix & suffix (default: +ElasticsearchRecord.decorate_table_names+)
          # @param [Hash] options
          # @return [Boolean] acknowledged status
          def clone_table(table_name, target_name, decorate: nil, **options)
            table_name  = _decorate_table_name(table_name, decorate: decorate)
            target_name = _decorate_table_name(target_name, decorate: decorate)

            # create new definition
            definition = clone_table_definition(table_name, target_name, **extract_table_options!(options))

            # yield optional block
            if block_given?
              definition.assign do |d|
                yield d
              end
            end

            # execute definition query(ies)
            definition.exec!
          end

          # creates a backup (snapshot) of the entire table (index) from provided +table_name+.
          # The backup will be closed, to prevent read/write access.
          # The +target_name+ will be auto-generated, if not provided.
          #
          # @example
          #   backup_table('screenshots', to: 'screenshots-backup-v1')
          #
          # @param [String] table_name
          # @param [String] to - target_name
          # @param [Boolean] close - closes backup after creation (default: true)
          # @param [Boolean] decorate - resolve both table names with the configured prefix & suffix (default: +ElasticsearchRecord.decorate_table_names+)
          # @return [String] backup_name
          def backup_table(table_name, to: nil, close: true, decorate: nil)
            table_name = _decorate_table_name(table_name, decorate: decorate)

            # IMPORTANT: the auto-generated name is built from the ALREADY resolved +table_name+, so
            # it stays within the current environment without being decorated a second time (which
            # would append the suffix BEHIND the '-snapshot-' part).
            to = to.nil? ? "#{table_name}-snapshot-#{Time.now.strftime('%s%3N')}" : _decorate_table_name(to, decorate: decorate)

            raise ArgumentError, "unable to backup '#{table_name}' to already existing target '#{to}'!" if table_exists?(to)

            clone_table(table_name, to, decorate: false)
            close_table(to, decorate: false) if close

            to
          end

          # restores a entire table (index) from provided +target_name+.
          # The +table_name+ will be dropped, if exists.
          # The +from+ will persist, if not provided +drop_backup:true+.
          #
          # IMPORTANT: both strategies restore through a +clone+, which inherits the settings of
          # its source - including the 'write'-block that is required to clone at all.
          # The restored table is therefore *open* but *read-only* until that block is released,
          # which is what the +unblock+ flag is for.
          # (there is no +open+ flag: a clone is always created open - even from a closed source)
          # see @ ActiveRecord::ConnectionAdapters::Elasticsearch::CloneTableDefinition#_before_exec
          #
          # @example
          #   restore_table('screenshots', from: 'screenshots-backup-v1')
          #
          # @example
          #   # keep the restored table read-only
          #   restore_table('screenshots', from: 'screenshots-backup-v1', unblock: false)
          #
          # @param [String] table_name
          # @param [String] from
          # @param [String (frozen)] timeout - renaming timout (default: '1m')
          # @param [Boolean] unblock - releases the inherited 'write'-block on the restored table (default: true)
          # @param [Boolean] drop_backup - renames instead of clones, which removes the +from+ (default: false)
          # @param [Boolean] decorate - resolve both table names with the configured prefix & suffix (default: +ElasticsearchRecord.decorate_table_names+)
          # @return [nil] - every failing step raises instead
          def restore_table(table_name, from:, timeout: '1m', unblock: true, drop_backup: false, decorate: nil)
            table_name = _decorate_table_name(table_name, decorate: decorate)
            from       = _decorate_table_name(from, decorate: decorate)

            raise ArgumentError, "unable to restore from missing target '#{from}'!" unless table_exists?(from)
            drop_table(table_name, if_exists: true, decorate: false)

            # choose best strategy
            if drop_backup
              rename_table(from, table_name, timeout: timeout, decorate: false)
            else
              clone_table(from, table_name, decorate: false)
            end

            # release the inherited 'write'-block, if provided
            unblock_table(table_name, :write, decorate: false) if unblock
          end

          # renames a table (index) by executing multiple steps:
          # - clone table
          # - wait for 'green' state
          # - drop old table
          # The +timeout+ option will define how long to wait for the 'green' state.
          #
          # @param [String] table_name
          # @param [String] target_name
          # @param [String (frozen)] timeout (default: '1m')
          # @param [Boolean] decorate - resolve both table names with the configured prefix & suffix (default: +ElasticsearchRecord.decorate_table_names+)
          # @param [Hash] options - additional 'clone' options (like settings, alias, ...)
          def rename_table(table_name, target_name, timeout: '1m', decorate: nil, **options)
            # IMPORTANT: both names must be resolved HERE and not only forwarded to the statements
            # below - the +schema_cache+ and the +cluster_health+ call in between address the index
            # directly and would otherwise miss the decorated one
            table_name  = _decorate_table_name(table_name, decorate: decorate)
            target_name = _decorate_table_name(target_name, decorate: decorate)

            # IMPORTANT: Clears out internal caches
            schema_cache.clear_data_source_cache!(table_name)

            clone_table(table_name, target_name, decorate: false, **options)
            cluster_health(index: target_name, wait_for_status: 'green', timeout: timeout)
            drop_table(table_name, decorate: false)
          end

          # creates a new table (index).
          # [<tt>:force</tt>]
          #   Set to +true+ to drop an existing index
          #   Defaults to false.
          # [<tt>:copy_from</tt>]
          #   Set to an existing index, to copy it's schema.
          # [<tt>:if_not_exists</tt>]
          #   Set to +true+ to skip creation if index already exists.
          #   Defaults to false.
          # @param [String] table_name
          # @param [Boolean] force - force a drop on the existing index (default: false)
          # @param [nil, String] copy_from - copy schema from existing index
          # @param [Boolean] if_not_exists - skip the creation if the index already exists (default: false)
          # @param [Boolean] decorate - resolve the table name (and +copy_from+) with the configured prefix & suffix (default: +ElasticsearchRecord.decorate_table_names+)
          # @param [Hash] options
          # @return [Boolean] acknowledged status
          def create_table(table_name, force: false, copy_from: nil, if_not_exists: false, decorate: nil, **options)
            table_name = _decorate_table_name(table_name, decorate: decorate)

            return if if_not_exists && table_exists?(table_name)

            # copy schema from existing table
            options.merge!(table_schema(_decorate_table_name(copy_from, decorate: decorate))) if copy_from

            # create new definition
            definition = create_table_definition(table_name, **extract_table_options!(options))

            # yield optional block
            if block_given?
              definition.assign do |d|
                yield d
              end
            end

            # force drop existing table
            if force
              drop_table(table_name, if_exists: true, decorate: false)
            else
              # IMPORTANT: Clears out internal caches
              schema_cache.clear_data_source_cache!(table_name)
            end

            # execute definition query(ies)
            definition.exec!
          end

          # A block for changing mappings, settings & aliases in +table+.
          #
          #   # change_table() yields a ChangeTableDefinition instance
          #   change_table(:suppliers) do |t|
          #     t.mapping :name, :string
          #     # Other column alterations here
          #   end
          #
          # @param [String] table_name
          # @param [Boolean] if_exists - skip if the index does not exist (default: false)
          # @param [Boolean] recreate - recreate the index from a copy of the current one (default: false)
          # @param [Boolean] decorate - resolve the table name with the configured prefix & suffix (default: +ElasticsearchRecord.decorate_table_names+)
          # @param [Hash] options
          def change_table(table_name, if_exists: false, recreate: false, decorate: nil, **options, &block)
            table_name = _decorate_table_name(table_name, decorate: decorate)

            return if if_exists && !table_exists?(table_name)

            # check 'recreate' flag.
            # If true, a 'create_table' with copy of the current will be executed
            return create_table(table_name, force: true, copy_from: table_name, decorate: false, **options, &block) if recreate

            # build new update definition
            definition = update_table_definition(table_name, self, **options)

            # yield optional block
            if block_given?
              definition.assign do |d|
                yield d
              end
            end

            # execute definition query(ies)
            definition.exec!
          end

          # Copies documents from a source to a destination.
          # @param [String] table_name
          # @param [String] target_name
          # @param [Boolean] decorate - resolve both table names with the configured prefix & suffix (default: +ElasticsearchRecord.decorate_table_names+)
          # @param [Hash] options
          # @return [Hash] reindex stats
          def reindex_table(table_name, target_name, decorate: nil, **options)
            table_name  = _decorate_table_name(table_name, decorate: decorate)
            target_name = _decorate_table_name(target_name, decorate: decorate)

            api(:reindex, { body: { source: { index: table_name }, dest: { index: target_name } } }.merge(options), 'REINDEX TABLE')
          end

          # -- mapping -------------------------------------------------------------------------------------------------
          #
          # PLEASE NOTE: every statement below reaches +#change_table+ through
          # +#_exec_change_table_with+, which forwards a provided +decorate:+ flag - only the TABLE
          # name is ever decorated, never the mapping / meta / setting / alias name.

          def add_mapping(table_name, name, type, **options, &block)
            _exec_change_table_with(:add_mapping, table_name, name, type, **options, &block)
          end

          alias :add_column :add_mapping

          # will fail unless +recreate:true+ option was provided
          def change_mapping(table_name, name, type, **options, &block)
            _exec_change_table_with(:change_mapping, table_name, name, type, **options, &block)
          end

          alias :change_column :change_mapping

          def remove_mapping(table_name, name, **options)
            _exec_change_table_with(:remove_mapping, table_name, name, **options)
          end

          alias :remove_column :remove_mapping

          def change_mapping_meta(table_name, name, **options)
            _exec_change_table_with(:change_mapping_meta, table_name, name, **options)
          end

          def change_mapping_attributes(table_name, name, **options, &block)
            _exec_change_table_with(:change_mapping_attributes, table_name, name, **options, &block)
          end

          def change_meta(table_name, name, value, **options)
            _exec_change_table_with(:change_meta, table_name, name, value, **options)
          end

          def remove_meta(table_name, name, **options)
            _exec_change_table_with(:remove_meta, table_name, name, **options)
          end

          # -- setting -------------------------------------------------------------------------------------------------

          def add_setting(table_name, name, value, **options, &block)
            _exec_change_table_with(:add_setting, table_name, name, value, **options, &block)
          end

          def change_setting(table_name, name, value, **options, &block)
            _exec_change_table_with(:change_setting, table_name, name, value, **options, &block)
          end

          def remove_setting(table_name, name, **options, &block)
            _exec_change_table_with(:remove_setting, table_name, name, **options, &block)
          end

          # -- alias ---------------------------------------------------------------------------------------------------

          def add_alias(table_name, name, **options, &block)
            _exec_change_table_with(:add_alias, table_name, name, **options, &block)
          end

          def change_alias(table_name, name, **options, &block)
            _exec_change_table_with(:change_alias, table_name, name, **options, &block)
          end

          def remove_alias(table_name, name, **options, &block)
            _exec_change_table_with(:remove_alias, table_name, name, **options, &block)
          end

          # recaps a provided +table_name+ with optionally configured +table_name_prefix+ & +table_name_suffix+.
          # This depends on the connection config of the current environment.
          #
          # PLEASE NOTE: the method is idempotent through a +start_with?+ / +end_with?+ check, so it
          # can safely be called on an already resolved name. That check cannot tell a resolved name
          # apart from a base name that legitimately starts with the prefix (or ends with the
          # suffix) - use +decorate: false+ on the statement to address such an index literally.
          #
          # @param [String] table_name
          # @return [String]
          def _env_table_name(table_name)
            # ensure *table_name* is a string
            table_name = table_name.to_s

            # ensure *prefix* and *suffix* are strings
            prefix = table_name_prefix.to_s
            suffix = table_name_suffix.to_s

            # HINT: +"" creates a new +unfrozen+ string!
            name = +""
            name << prefix unless table_name.start_with?(prefix)
            name << table_name
            name << suffix unless table_name.end_with?(suffix)

            name
          end

          private

          # resolves the provided +table_name+ through +#_env_table_name+, unless the decoration was
          # disabled - either for this call (+decorate: false+) or globally.
          # @param [String, Symbol] table_name
          # @param [nil, Boolean] decorate - a nil-value resolves the global default
          # @return [String]
          def _decorate_table_name(table_name, decorate:)
            # only a NOT explicitly provided flag falls back to the global default, so a single
            # statement can always opt in or out on its own
            decorate = ElasticsearchRecord.decorate_table_names if decorate.nil?

            decorate ? _env_table_name(table_name) : table_name.to_s
          end

          # returns the AR-internal indices, which carry the migration state of the connection.
          # Both the resolved AND the decorated name are returned, so the check also holds if those
          # internal table names do not carry the prefix & suffix of the connection
          # (+ActiveRecord::InternalMetadata+ resolves through +ActiveRecord::Base+, so it may well
          # be undecorated while +ElasticsearchRecord::SchemaMigration+ is not).
          #
          # Used by +#truncate_table+ only - see the 'Internal tables' section of this module for
          # why +#drop_table+ deliberately passes them through.
          #
          # @return [Array<String>]
          def _internal_table_names
            names = [schema_migration.table_name, internal_metadata.table_name]

            names | names.map { |name| _env_table_name(name) }
          end

          # Executes a given table operation method within the context of a `change_table` block.
          #
          # This method wraps the provided `method` call in a `change_table` transaction. It allows performing
          # modifications such as adding, changing, or removing mappings, settings, or metadata on the specified table.
          #
          # @param [Symbol] method - The operation to perform (e.g., :add_mapping, :remove_mapping).
          # @param [String] table_name - The name of the table to modify.
          # @param [Array<Object>] args - Additional arguments to pass to the operation method.
          # @param [Boolean] recreate - Whether to recreate the table before applying changes (default: false).
          # @param [Boolean, nil] decorate - Whether to resolve the table name with a configured prefix and suffix (default: nil
          def _exec_change_table_with(method, table_name, *args, recreate: false, decorate: nil, **kwargs, &block)
            change_table(table_name, recreate: recreate, decorate: decorate) do |t|
              t.send(method, *args, **kwargs, &block)
            end
          end
        end
      end
    end
  end
end
