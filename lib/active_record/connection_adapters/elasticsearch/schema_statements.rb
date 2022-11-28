# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      module SchemaStatements # :nodoc:

        # temporary workaround
        # toDo: fixme
        def create_table(*_args)
          $stdout.puts "\n>>> 'create_table' elasticsearch is not supported - the following message is insignificant!"
        end

        # # temporary workaround
        # # toDo: fixme
        # def assume_migrated_upto_version(version)
        #   $stdout.puts "\n>>> 'assume_migrated_upto_version' elasticsearch is not supported - the following message is insignificant!"
        # end

        # ALWAYS returns an empty array, since elasticsearch does not support individual indexes...
        def indexes(_table_name)
          []
        end

        # Returns the relation names usable to back Active Record models.
        # For Elasticsearch this means all indices - which also includes system +dot+ '.' indices.
        # @see ActiveRecord::ConnectionAdapters::SchemaStatements#data_sources
        # @return [Array<String>]
        def data_sources
          api(:indices, :get_settings, { index: :_all }, 'SCHEMA').keys
        end

        # returns a hash of all mappings by provided table_name (index)
        # @param [String] table_name
        # @return [Hash]
        def table_mappings(table_name)
          api(:indices, :get_mapping, { index: table_name }, 'SCHEMA').dig(table_name, 'mappings')
        end

        # returns a hash of all settings by provided table_name
        # @param [String] table_name
        # @return [Hash]
        def table_settings(table_name)
          api(:indices, :get_settings, { index: table_name }, 'SCHEMA').dig(table_name, 'settings', 'index')
        end

        # returns a hash of all aliases by provided index_name
        # @param [String] table_name
        # @return [Hash]
        def table_aliases(table_name)
          api(:indices, :get_alias, { index: table_name }, 'SCHEMA').dig(table_name, 'aliases')
        end

        # returns a hash of the full definition of the provided index_name.
        # (includes settings, mappings & aliases)
        # @param [String] table_name
        # @return [Hash]
        def table_schema(table_name)
          {
            settings: table_settings(table_name),
            mappings: table_mappings(table_name),
            aliases:  table_aliases(table_name)
          }.compact_blank
        end

        # Returns the list of a table's column names, data types, and default values.
        # @see ActiveRecord::ConnectionAdapters::SchemaStatements#columns
        # @see ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter#column_definitions
        # @param [String] table_name
        # @return [Array<Hash>]
        def column_definitions(table_name)
          mappings = table_mappings(table_name)

          # prevent exceptions on missing mappings, to provide the possibility to create them
          # otherwise loading the table (index) will always fail!
          mappings = { 'properties' => {} } if mappings.blank? || mappings['properties'].blank?
          # raise(ActiveRecord::StatementInvalid, "Could not find valid mappings for '#{table_name}'") if mappings.blank? || mappings['properties'].blank?

          # since the received mappings do not have the "primary" +_id+-column we manually need to add this here
          # The BASE_STRUCTURE will also include some meta keys like '_score', '_type', ...
          ActiveRecord::ConnectionAdapters::ElasticsearchAdapter::BASE_STRUCTURE + mappings['properties'].map { |key, prop|
            # resolve (nested) fields and properties
            fields, properties = resolve_fields_and_properties(key, prop, true)

            # fallback for possible empty type
            type = prop['type'].presence || (properties.present? ? 'object' : 'nested')

            # return a new hash
            prop.merge('name' => key, 'type' => type, 'fields' => fields, 'properties' => properties)
          }
        end

        # creates a new column object from provided field Hash
        # @see ActiveRecord::ConnectionAdapters::SchemaStatements#columns
        # @see ActiveRecord::ConnectionAdapters::MySQL::SchemaStatements#new_column_from_field
        # @param [String] _table_name
        # @param [Hash] field
        # @return [ActiveRecord::ConnectionAdapters::Column]
        def new_column_from_field(_table_name, field)
          ActiveRecord::ConnectionAdapters::Elasticsearch::Column.new(
            field["name"],
            field["null_value"],
            fetch_type_metadata(field["type"]),
            comment:    ((field['meta'] && field['meta']['comment']) ? field['meta']['comment'] : nil),
            virtual:    field['virtual'],
            fields:     field['fields'],
            properties: field['properties']
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
        # To not break the "ConnectionAdapters" concept we simulate this through the +meta+ attribute.
        # @see ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter#primary_keys
        # @param [String] table_name
        def primary_keys(table_name)
          column_definitions(table_name)
          # ActiveRecord::ConnectionAdapters::ElasticsearchAdapter::BASE_STRUCTURE
            .select { |f| f['meta'] && f['meta']['primary_key'] == 'true' }
            # only take the last found primary key (if no custom primary_key was provided this will return +_id+ )
            .map { |f| f["name"] }[-1..-1]
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

        # overwrite original methods to provide a elasticsearch version
        def create_schema_dumper(options)
          ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaDumper.create(self, options)
        end

        # overwrite original methods to provide a elasticsearch version
        def create_table_definition(name, **options)
          ::ActiveRecord::ConnectionAdapters::Elasticsearch::TableDefinition.new(self, name, **options)
        end

        # returns the maximum allowed size for queries for the provided +table_name+.
        # The query will raise an ActiveRecord::StatementInvalid if the requested limit is above this value.
        # @return [Integer]
        def max_result_window(table_name)
          table_settings(table_name).dig('max_result_window').presence || 10000
        end

        private

        # returns a multidimensional array with fields & properties from the provided +prop+.
        # Nested fields & properties will be also detected.
        # .
        #   resolve_fields_and_properties('user', {...})
        #   # > [
        #     # fields
        #     [0] [
        #         [0] {
        #             "name" => "user.name.analyzed",
        #             "type" => "text"
        #         }
        #     ],
        #     # properties
        #     [1] [
        #         [0] {
        #             "name" => "user.id",
        #             "type" => "integer"
        #         },
        #         [1] {
        #             "name" => "user.name",
        #             "type" => "keyword"
        #         }
        #     ]
        # ]
        #
        # @param [String] key
        # @param [Hash] prop
        # @param [Boolean] root - provide true, if this is a top property entry (default: false)
        # @return [[Array, Array]]
        def resolve_fields_and_properties(key, prop, root = false)
          # mappings can have +fields+ - we also want them for 'query-conditions'
          fields = (prop['fields'] || {}).map { |field_key, field_def|
            { 'name' => "#{key}.#{field_key}", 'type' => field_def['type'] }
          }

          # initial empty array
          properties = []

          if prop['properties'].present?
            prop['properties'].each do |nested_key, nested_prop|
              nested_fields, nested_properties = resolve_fields_and_properties("#{key}.#{nested_key}", nested_prop)
              fields                           |= nested_fields
              properties                       |= nested_properties
            end
          elsif !root # don't add the root property as sub-property
            properties << { 'name' => key, 'type' => prop['type'] }
          end

          [fields, properties]
        end

        # overwrite original methods to provide a elasticsearch version
        def schema_creation
          ::ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaCreation.new(self)
        end

        # overwrite original methods to provide a elasticsearch version
        def extract_table_options!(options)
          ::ActiveRecord::ConnectionAdapters::Elasticsearch::TableDefinition.extract_table_options!(options)
        end
      end
    end
  end
end
