# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      module SchemaStatements # :nodoc:
        # Returns the relation names usable to back Active Record models.
        # For Elasticsearch this means all indices - which also includes system +dot+ '.' indices.
        # @see ActiveRecord::ConnectionAdapters::SchemaStatements#data_sources
        # @return [Array<String>]
        def data_sources
          api(:indices, :get_settings, { index: :_all }, 'SCHEMA').keys
        end

        # returns a array of all mappings by provided table_name
        # @param [String] table_name
        def mappings(table_name)
          api(:indices, :get_mapping, { index: table_name }, 'SCHEMA').dig(table_name, 'mappings')
        end

        # Returns the list of a table's column names, data types, and default values.
        # @see ActiveRecord::ConnectionAdapters::SchemaStatements#columns
        # @see ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter#column_definitions
        # @param [String] table_name
        # @return [Array<Hash>]
        def column_definitions(table_name)
          structure = mappings(table_name)
          raise(ActiveRecord::StatementInvalid, "Could not find elasticsearch index '#{table_name}'") if structure.blank? || structure['properties'].blank?

          # since the received mappings do not have the "primary" +_id+-column we manually need to add this here
          # The BASE_STRUCTURE will also include some meta keys like '_score', '_type', ...
          ActiveRecord::ConnectionAdapters::ElasticsearchAdapter::BASE_STRUCTURE + structure['properties'].map { |key, prop|
            # mappings can have +fields+ - we also want them for 'query-conditions'
            # that can be resolved through +.column_names+
            fields = prop.delete('fields') || []

            # we need to merge the name & possible nested fields (which are also searchable)
            prop.merge('name' => key, 'fields' => fields.map { |fkey, _field| "#{key}.#{fkey}" })
          }
        end

        # creates a new column object from provided field Hash
        # @see ActiveRecord::ConnectionAdapters::SchemaStatements#columns
        # @see ActiveRecord::ConnectionAdapters::MySQL::SchemaStatements#new_column_from_field
        # @param [String] _table_name
        # @param [Hash] field
        # @return [ActiveRecord::ConnectionAdapters::Column]
        def new_column_from_field(_table_name, field)
          # fallback for possible empty type
          field_type = field['type'].presence || (field['properties'].present? ? 'nested' : 'object')

          type_metadata = fetch_type_metadata(field_type)

          ActiveRecord::ConnectionAdapters::Elasticsearch::Column.new(
            field["name"],
            field["null_value"],
            type_metadata,
            field['null'].nil? ? true : field['null'],
            nil,
            comment: field['meta'] ? field['meta'].map { |k, v| "#{k}: #{v}" }.join(' | ') : nil,
            virtual: field['virtual'],
            fields:  field['fields']
          )
        end

        # lookups from building the @columns_hash.
        # since Elasticsearch has the "feature" to provide multicast values on any type, we need to fetch them ...
        # you know, ES can return an integer or an array of integers for any column ...
        # @param [ActiveRecord::ConnectionAdapters::Elasticsearch::Column] column
        # @return [ActiveRecord::ConnectionAdapters::Elasticsearch::Type::MulticastValue]
        def lookup_cast_type_from_column(column)
          type_map.lookup(:multicast_value, super)
        end

        # Returns a array of tables primary keys.
        # PLEASE NOTE: Elasticsearch does not have a concept of primary key.
        # The only thing that uniquely identifies a document is the index together with the +_id+.
        # To not break the "ConnectionAdapters" concept we simulate this through the BASE_STRUCTURE.
        # We know, we can just return '_id' here ...
        # @see ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter#primary_keys
        # @param [String] _table_name
        def primary_keys(_table_name)
          ActiveRecord::ConnectionAdapters::ElasticsearchAdapter::BASE_STRUCTURE
            .select { |f| f["primary"] }
            .map { |f| f["name"] }
        end

        # Checks to see if the data source +name+ exists on the database.
        #
        #   data_source_exists?(:ebooks)
        # @see ActiveRecord::ConnectionAdapters::SchemaStatements#data_source_exists?
        # @param [String, Symbol] name
        # @return [Boolean]
        def data_source_exists?(name)
          # response returns boolean
          api(:indices, :exists?, { index: name }, 'SCHEMA')
        end

        # Returns an array of table names defined in the database.
        # For Elasticsearch this means all normal indices (no system +dot+ '.' indices)
        # @see ActiveRecord::ConnectionAdapters::SchemaStatements#tables
        # @return [Array<String>]
        def tables
          data_sources.reject { |key| key[0] == '.' }
        end

        # Checks to see if the table +table_name+ exists on the database.
        #
        #   table_exists?(:developers)
        #
        # @see ActiveRecord::ConnectionAdapters::SchemaStatements#table_exists?
        # @param [String, Symbol] table_name
        # @return [Boolean]
        def table_exists?(table_name)
          # just reference to the data sources
          data_source_exists?(table_name)
        end
      end
    end
  end
end
