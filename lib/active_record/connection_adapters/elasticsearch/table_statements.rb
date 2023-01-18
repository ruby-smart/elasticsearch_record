# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      # extend adapter with table-related statements
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
                                    :change_column_default, :change_column_null, :rename_column, :rename_table

          # Opens a closed index.
          # @param [String] table_name
          # @return [Boolean] acknowledged status
          def open_table(table_name)
            schema_cache.clear_data_source_cache!(table_name)
            api(:indices, :open, { index: table_name }, 'OPEN TABLE').dig('acknowledged')
          end

          # Opens closed indices.
          # @param [Array] table_names
          # @return [Array] acknowledged status for each provided table
          def open_tables(*table_names)
            table_names -= [schema_migration.table_name, InternalMetadata.table_name]
            return if table_names.empty?

            table_names.map { |table_name| open_table(table_name) }
          end

          # Closes an index.
          # @param [String] table_name
          # @return [Boolean] acknowledged status
          def close_table(table_name)
            schema_cache.clear_data_source_cache!(table_name)
            api(:indices, :close, { index: table_name }, 'CLOSE TABLE').dig('acknowledged')
          end

          # Closes indices by provided names.
          # @param [Array] table_names
          # @return [Array] acknowledged status for each provided table
          def close_tables(*table_names)
            table_names -= [schema_migration.table_name, InternalMetadata.table_name]
            return if table_names.empty?

            table_names.map { |table_name| close_table(table_name) }
          end

          # refresh an index.
          # A refresh makes recent operations performed on one or more indices available for search.
          # raises an exception if the index could not be found.
          #
          # @param [String] table_name
          # @return [Boolean] result state (returns false if refreshing failed)
          def refresh_table(table_name)
            api(:indices, :refresh, { index: table_name }, 'REFRESH TABLE').dig('_shards', 'failed') == 0
          end

          # refresh indices by provided names.
          # @param [Array] table_names
          # @return [Array] result state (returns false if refreshing failed)
          def refresh_tables(*table_names)
            table_names -= [schema_migration.table_name, InternalMetadata.table_name]
            return if table_names.empty?

            table_names.map { |table_name| refresh_table(table_name) }
          end

          # truncates index by provided name.
          # HINT: Elasticsearch does not have a +truncate+ concept:
          # - so we have to store the current index' schema
          # - drop the index
          # - and create it again
          # @param [String] table_name
          # @return [Boolean] acknowledged status
          def truncate_table(table_name)
            # force: automatically drops an existing index
            create_table(table_name, force: true, **table_schema(table_name))
          end

          alias :truncate :truncate_table

          # truncate indices by provided names.
          # @param [Array] table_names
          # @return [Array] acknowledged status for each provided table
          def truncate_tables(*table_names)
            table_names -= [schema_migration.table_name, InternalMetadata.table_name]
            return if table_names.empty?

            table_names.map { |table_name| truncate_table(table_name) }
          end

          # drops an index
          # [<tt>:if_exists</tt>]
          #   Set to +true+ to only drop the table if it exists.
          #   Defaults to false.
          # @param [String] table_name
          # @param [Boolean] if_exists
          # @return [Array] acknowledged status
          def drop_table(table_name, if_exists: false, **)
            schema_cache.clear_data_source_cache!(table_name)
            api(:indices, :delete, { index: table_name, ignore: (if_exists ? 404 : nil) }, 'DROP TABLE').dig('acknowledged')
          end

          # blocks access to the provided table (index) and +block+ name.
          # @param [String] table_name
          # @param [Symbol] block_name The block to add (one of :read, :write, :read_only or :metadata)
          # @return [Boolean] acknowledged status
          def block_table(table_name, block_name = :write)
            api(:indices, :add_block, { index: table_name, block: block_name }, "BLOCK #{block_name.to_s.upcase} TABLE").dig('acknowledged')
          end

          # unblocks access to the provided table (index) and +block+ name.
          # provide a nil-value to unblock all blocks, otherwise provide the blocked name.
          # @param [String] table_name
          # @param [Symbol] block_name The block to add (one of :read, :write, :read_only or :metadata)
          # @return [Boolean] acknowledged status
          def unblock_table(table_name, block_name = nil)
            if block_name.nil?
              change_table(table_name) do |t|
                t.change_setting('index.blocks.read', nil)
                t.change_setting('index.blocks.write', nil)
                t.change_setting('index.blocks.read_only', nil)
                t.change_setting('index.blocks.metadata', nil)
              end
            else
              change_setting(table_name, "index.blocks.#{block_name}", nil)
            end
          end

          # clones an entire table (index) to the provided +target_name+.
          # During cloning, the table will be automatically 'write'-blocked.
          # @param [String] table_name
          # @param [String] target_name
          # @param [Hash] options
          def clone_table(table_name, target_name, **options)
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

          # renames a table (index) by executing multiple steps:
          # - clone table
          # - wait for 'green' state
          # - drop old table
          # The +timeout+ option will define how long to wait for the 'green' state.
          #
          # @param [String] table_name
          # @param [String] target_name
          # @param [String (frozen)] timeout (default: '30s')
          # @param [Hash] options - additional 'clone' options (like settings, alias, ...)
          def rename_table(table_name, target_name, timeout: '30s', **options)
            schema_cache.clear_data_source_cache!(table_name)

            clone_table(table_name, target_name, **options)
            cluster_health(index: target_name, wait_for_status: 'green', timeout: timeout)
            drop_table(table_name)
          end

          # creates a new table (index).
          # [<tt>:force</tt>]
          #   Set to +true+ to drop an existing table
          #   Defaults to false.
          # [<tt>:copy_from</tt>]
          #   Set to an existing index, to copy it's schema.
          # [<tt>:if_not_exists</tt>]
          #   Set to +true+ to skip creation if table already exists.
          #   Defaults to false.
          # @param [String] table_name
          # @param [Boolean] force - force a drop on the existing table (default: false)
          # @param [nil, String] copy_from - copy schema from existing table
          # @param [Hash] options
          # @return [Boolean] acknowledged status
          def create_table(table_name, force: false, copy_from: nil, if_not_exists: false, **options)
            return if if_not_exists && table_exists?(table_name)

            # copy schema from existing table
            options.merge!(table_schema(copy_from)) if copy_from

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
              drop_table(table_name, if_exists: true)
            else
              schema_cache.clear_data_source_cache!(table_name.to_s)
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
          def change_table(table_name, if_exists: false, recreate: false, **options, &block)
            return if if_exists && !table_exists?(table_name)

            # check 'recreate' flag.
            # If true, a 'create_table' with copy of the current will be executed
            return create_table(table_name, force: true, copy_from: table_name, **options, &block) if recreate

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

          # -- mapping -------------------------------------------------------------------------------------------------

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
          # @param [String] table_name
          # @return [String]
          def _env_table_name(table_name)
            table_name = table_name.to_s

            # HINT: +"" creates a new +unfrozen+ string!
            name = +""
            name << table_name_prefix unless table_name.start_with?(table_name_prefix)
            name << table_name
            name << table_name_suffix unless table_name.end_with?(table_name_suffix)

            name
          end

          private

          def _exec_change_table_with(method, table_name, *args, recreate: false, **kwargs, &block)
            change_table(table_name, recreate: recreate) do |t|
              t.send(method, *args, **kwargs, &block)
            end
          end
        end
      end
    end
  end
end