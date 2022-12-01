# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      # extend adapter with schema-related statements
      #
      # *ORIGINAL* methods untouched:
      # - internal_string_options_for_primary_key
      # - options_include_default?
      # - fetch_type_metadata
      # - column_exists?
      #
      # *SUPPORTED* but not used:
      # - strip_table_name_prefix_and_suffix
      #
      # *UNSUPPORTED* methods that will be +ignored+:
      # - native_database_types
      # - table_options
      # - table_comment
      # - table_alias_for
      # - columns_for_distinct
      # - extract_new_default_value
      # - insert_versions_sql
      # - data_source_sql
      # - quoted_scope
      # - add_column_for_alter
      # - rename_column_sql
      # - remove_column_for_alter
      # - remove_columns_for_alter
      # - add_timestamps_for_alter
      # - remove_timestamps_for_alter
      # - foreign_key_name
      # - foreign_key_for
      # - foreign_key_for!
      # - extract_foreign_key_action
      # - check_constraint_name
      # - check_constraint_for
      # - check_constraint_for!
      # - validate_index_length!
      # - can_remove_index_by_name?
      # - index_column_names
      # - index_name_options
      # - add_index_sort_order
      # - options_for_index_columns
      # - add_options_for_index_columns
      # - index_name_for_remove
      # - add_index_options
      # - index_algorithm
      # - quoted_columns_for_index
      # - check_constraint_options
      # - check_constraints
      # - foreign_key_exists?
      # - foreign_key_column_for
      # - foreign_key_options
      # - foreign_keys
      # - index_name_exists?
      # - indexes
      # - index_name
      # - index_exists?
      #
      # *UNSUPPORTED* methods that will +fail+:
      # - views
      # - view_exists?
      # - add_index
      # - remove_index
      # - rename_index
      # - add_reference
      # - remove_reference
      # - add_foreign_key
      # - remove_foreign_key
      # - add_check_constraint
      # - remove_check_constraint
      # - rename_table_indexes
      # - rename_column_indexes
      # - create_alter_table
      # - insert_fixture
      # - insert_fixtures_set
      # - bulk_change_table
      # - dump_schema_information
      #
      # OVERWRITTEN methods for Elasticsearch:
      # ...
      module SchemaStatements
        extend ActiveSupport::Concern

        included do
          define_unsupported_method :views, :view_exists?, :add_index, :remove_index, :rename_index, :add_reference,
                                    :remove_reference, :add_foreign_key, :remove_foreign_key, :add_check_constraint,
                                    :remove_check_constraint, :rename_table_indexes, :rename_column_indexes,
                                    :create_alter_table, :insert_fixture, :insert_fixtures_set, :bulk_change_table,
                                    :dump_schema_information

          def assume_migrated_upto_version(version)
            version = version.to_i
            migrated = migration_context.get_all_versions
            versions = migration_context.migrations.map(&:version)

            unless migrated.include?(version)
              # use a ActiveRecord syntax to create a new version
              schema_migration.create(version: version)
            end

            inserting = (versions - migrated).select { |v| v < version }
            if inserting.any?
              if (duplicate = inserting.detect { |v| inserting.count(v) > 1 })
                raise "Duplicate migration #{duplicate}. Please renumber your migrations to resolve the conflict."
              end

              # use a ActiveRecord syntax to create new versions
              inserting.each {|iversion| schema_migration.create(version: iversion) }
            end

            true
          end

          # Returns the relation names usable to back Active Record models.
          # For Elasticsearch this means all indices - which also includes system +dot+ '.' indices.
          # @see ActiveRecord::ConnectionAdapters::SchemaStatements#data_sources
          # @return [Array<String>]
          def data_sources
            api(:indices, :get, { index: :_all, expand_wildcards: [:open, :closed] }, 'SCHEMA').keys
          end

          # Returns an array of table names defined in the database.
          # For Elasticsearch this means all normal indices (no system +dot+ '.' indices)
          # @see ActiveRecord::ConnectionAdapters::SchemaStatements#tables
          # @return [Array<String>]
          def tables
            data_sources.reject { |key| key[0] == '.' }
          end

          # returns a hash of all mappings by provided table_name (index)
          # @param [String] table_name
          # @return [Hash]
          def table_mappings(table_name)
            api(:indices, :get_mapping, { index: table_name, expand_wildcards: [:open, :closed] }, 'SCHEMA').dig(table_name, 'mappings')
          end

          # returns a hash of all settings by provided table_name
          # @param [String] table_name
          # @param [Boolean] flat_settings (default: true)
          # @return [Hash]
          def table_settings(table_name, flat_settings = true)
            api(:indices, :get_settings, { index: table_name, expand_wildcards: [:open, :closed], flat_settings: flat_settings }, 'SCHEMA').dig(table_name, 'settings')
          end

          # returns a hash of all aliases by provided table_name (index).
          # @param [String] table_name
          # @return [Hash]
          def table_aliases(table_name)
            api(:indices, :get_alias, { index: table_name, expand_wildcards: [:open, :closed] }, 'SCHEMA').dig(table_name, 'aliases')
          end

          # returns information about number of primaries and replicas, document counts, disk size, ... by provided table_name (index).
          # @param [String] table_name
          # @return [Hash]
          def table_state(table_name)
            response = api(:cat, :indices, { index: table_name, expand_wildcards: [:open, :closed] }, 'SCHEMA')

            [:health, :status, :name, :uuid, :pri, :rep, :docs_count, :docs_deleted, :store_size, :pri_store_size].zip(
              response.body.split(' ')
            ).to_h
          end

          # returns a hash of the full definition of the provided table_name (index).
          # (includes settings, mappings & aliases)
          # @param [String] table_name
          # @param [Array, Symbol] features
          # @return [Hash]
          def table_schema(table_name, features = [:aliases, :mappings, :settings])
            if cluster_info[:version] >= '8.5.0'
              response = api(:indices, :get, { index: table_name, expand_wildcards: [:open, :closed], features: features, flat_settings: true }, 'SCHEMA')
            else
              response = api(:indices, :get, { index: table_name, expand_wildcards: [:open, :closed], flat_settings: true }, 'SCHEMA')
            end

            {
              settings: response.dig(table_name, 'settings'),
              mappings: response.dig(table_name, 'mappings'),
              aliases:  response.dig(table_name, 'aliases')
            }
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
              meta:       field['meta'],
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
            api(:indices, :exists?, { index: name, expand_wildcards: [:open, :closed] }, 'SCHEMA')
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

          # Checks to see if a alias +alias_name+ within a table +table_name+ exists on the database.
          #
          #   alias_exists?(:developers, 'my-alias')
          #
          # @param [String] table_name
          # @param [String, Symbol] alias_name
          # @return [Boolean]
          def alias_exists?(table_name, alias_name)
            table_aliases(table_name).keys.include?(alias_name.to_s)
          end

          # Checks to see if a setting +setting_name+ within a table +table_name+ exists on the database.
          # The provided +setting_name+ must be flat!
          #
          #   setting_exists?(:developers, 'index.number_of_replicas')
          #
          # @param [String] table_name
          # @param [String,Symbol] setting_name
          # @return [Boolean]
          def setting_exists?(table_name, setting_name)
            table_settings(table_name).keys.include?(setting_name.to_s)
          end

          # Checks to see if a mapping +mapping_name+ within a table +table_name+ exists on the database.
          #
          #   mapping_exists?(:developers, :status, :integer)
          #
          # @param [String, Symbol] table_name
          # @param [String, Symbol] mapping_name
          # @return [Boolean]
          def mapping_exists?(table_name, mapping_name, type = nil)
            column_exists?(table_name, mapping_name, type)
          end

          # overwrite original methods to provide a elasticsearch version
          def create_schema_dumper(options)
            ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaDumper.create(self, options)
          end

          # overwrite original methods to provide a elasticsearch version
          def create_table_definition(name, **options)
            ::ActiveRecord::ConnectionAdapters::Elasticsearch::CreateTableDefinition.new(self, name, **options)
          end

          # overwrite original methods to provide a elasticsearch version
          def update_table_definition(name, base = self, **options)
            # :nodoc:
            ::ActiveRecord::ConnectionAdapters::Elasticsearch::UpdateTableDefinition.new(base, name, **options)
          end

          # overwrite original methods to provide a elasticsearch version
          def schema_creation
            ::ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaCreation.new(self)
          end

          # returns the maximum allowed size for queries for the provided +table_name+.
          # The query will raise an ActiveRecord::StatementInvalid if the requested limit is above this value.
          # @return [Integer]
          def max_result_window(table_name)
            table_settings(table_name).dig('index', 'max_result_window').presence || 10000
          end

          # Returns basic information about the cluster.
          # @return [Hash{Symbol->Unknown}]
          def cluster_info
            @cluster_info ||= begin
                                response = api(:core, :info, {}, 'CLUSTER')

                                {
                                  name:           response.dig('name'),
                                  cluster_name:   response.dig('cluster_name'),
                                  cluster_uuid:   response.dig('cluster_uuid'),
                                  version:        Gem::Version.new(response.dig('version', 'number')),
                                  lucene_version: response.dig('version', 'lucene_version')
                                }
                              end
          end

          # transforms provided schema-type to a sql-type
          # @param [String, Symbol] type
          # @param [String]
          def type_to_sql(type, **)
            return '' if type.blank?

            if (native = native_database_types[type.to_sym])
              (native.is_a?(Hash) ? native[:name] : native).dup
            else
              type.to_s
            end
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
          def extract_table_options!(options)
            options.extract!(:settings, :mappings, :aliases, :force, :strict)
          end
        end
      end
    end
  end
end