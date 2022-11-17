# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      module DatabaseStatements

        # truncate index by provided name
        def truncate(index_name)
          # force automatically drops an existing index
          create_table(index_name, **table_schema(index_name).merge(force: true))
        end

        # truncate tables by provided names.
        # (does not really truncate - it copies it's schema, deletes the index & recreates it)
        # @param [Array] index_names
        def truncate_tables(*index_names)
          index_names -= [schema_migration.table_name, InternalMetadata.table_name]
          return if index_names.empty?

          index_names.map { |index_name| truncate(index_name) }
        end

        # drops a table
        # [<tt>:if_exists</tt>]
        #   Set to +true+ to only drop the table if it exists.
        #   Defaults to false.
        # @param [String] index_name
        # @param [Hash] options
        def drop_table(index_name, **options)
          # toDO: remove ME!
          return
          schema_cache.clear_data_source_cache!(index_name.to_s)
          api(:indices, :delete, {index: index_name, ignore: (options[:if_exists] ? 404 : nil) }, 'DROP')
        end

        def create_table(index_name, force: false, **options)
          td = create_table_definition(index_name, **extract_table_options!(options))

          yield td if block_given?

          if force
            drop_table(index_name, if_exists: true)
          else
            schema_cache.clear_data_source_cache!(index_name.to_s)
          end

          query = schema_creation.accept td


          Debugger.debug(query,"query")
          raise "NOPE"

          result = execute query


        end
      end
    end
  end
end
