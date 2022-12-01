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
          #
          # UPCOMING future methods:
          # - clone (option -> close, or read-only (#lock / unlock) )
          # - refresh
          # - rename_table

          define_unsupported_method :rename_table

          # Opens a closed index.
          # @param [String] table_name
          # @return [Boolean] acknowledged status
          def open_table(table_name)
            schema_cache.clear_data_source_cache!(table_name.to_s)
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
            schema_cache.clear_data_source_cache!(table_name.to_s)
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
          # @param [Hash] options
          # @return [Array] acknowledged status for provided table
          def drop_table(table_name, **options)
            schema_cache.clear_data_source_cache!(table_name.to_s)
            api(:indices, :delete, { index: table_name, ignore: (options[:if_exists] ? 404 : nil) }, 'DROP TABLE').dig('acknowledged')
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
          def change_table(table_name, **options)
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

          def change_mapping(table_name, name, type, **options, &block)
            _exec_change_table_with(:change_mapping, table_name, name, type, **options, &block)
          end

          alias :change_column :change_mapping

          def change_mapping_meta(table_name, name, **options)
            _exec_change_table_with(:change_mapping_meta, table_name, name, **options)
          end

          def change_mapping_attributes(table_name, name, **options,&block)
            _exec_change_table_with(:change_mapping_attributes, table_name, name, **options, &block)
          end
          alias :change_mapping_attribute :change_mapping_attributes

          # -- setting -------------------------------------------------------------------------------------------------

          def add_setting(table_name, name, value, **options, &block)
            _exec_change_table_with(:add_setting, table_name, name, value, **options, &block)
          end

          def change_setting(table_name, name, value, **options, &block)
            _exec_change_table_with(:change_setting, table_name, name, value, **options, &block)
          end

          def delete_setting(table_name, name, **options, &block)
            _exec_change_table_with(:delete_setting, table_name, name, **options, &block)
          end

          # -- alias ---------------------------------------------------------------------------------------------------

          def add_alias(table_name, name, **options, &block)
            _exec_change_table_with(:add_alias, table_name, name, **options, &block)
          end

          def change_alias(table_name, name, **options, &block)
            _exec_change_table_with(:change_alias, table_name, name, **options, &block)
          end

          def delete_alias(table_name, name, **options, &block)
            _exec_change_table_with(:delete_alias, table_name, name, **options, &block)
          end

          private

          def _exec_change_table_with(method, table_name, *args, **kwargs, &block)
            change_table(table_name) do |t|
              t.send(method, *args, **kwargs, &block)
            end
          end
        end
      end
    end
  end
end