# frozen_string_literal: true

require 'active_record/connection_adapters/elasticsearch/schema_definitions/table_definition'

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class CreateTableDefinition < TableDefinition
        def initialize(conn, name, settings: nil, mappings: nil, aliases: nil, **opts)
          super(conn, name, **opts)

          @settings = HashWithIndifferentAccess.new
          @mappings = HashWithIndifferentAccess.new
          @aliases  = HashWithIndifferentAccess.new

          transform_settings!(settings) if settings.present?
          transform_mappings!(mappings) if mappings.present?
          transform_aliases!(aliases) if aliases.present?
        end

        # returns an array with all +TableSettingDefinition+.
        # @return [Array]
        def settings
          @settings.values
        end

        # returns an array with all +TableMappingDefinition+.
        # @return [Array]
        def mappings
          @mappings.values
        end

        # provide backwards compatibility to columns
        alias columns mappings

        # returns an array with all +TableAliasDefinition+.
        # @return [Array]
        def aliases
          @aliases.values
        end

        # Returns a MappingDefinition for the mapping with name +name+.
        def [](name)
          @mappings[name]
        end

        ######################
        # DEFINITION METHODS #
        ######################

        # adds a new mapping
        def mapping(name, type, force: false, **options, &block)
          raise ArgumentError, "you cannot define an already defined mapping '#{name}'!" if @mappings.key?(name) && !force?(force)

          @mappings[name] = new_mapping_definition(name, type, **options, &block)

          self
        end

        # provide backwards compatibility to columns
        alias column mapping

        def remove_mapping(name)
          @mappings.delete(name)
        end

        # provide backwards compatibility to columns
        alias remove_column remove_mapping

        def setting(name, value, force: false, **options, &block)
          raise ArgumentError, "you cannot define an already defined setting '#{name}'!" if @settings.key?(name) && !force?(force)

          @settings[name] = new_setting_definition(name, value, **options, &block)

          self
        end

        def remove_setting(name)
          @settings.delete name
        end

        # we can use +alias+ here, since the instance method is not a reserved keyword!

        def alias(name, force: false, **options, &block)
          raise ArgumentError, "you cannot define an already defined alias '#{name}'." if @aliases.key?(name) && !force?(force)

          @aliases[name] = new_alias_definition(name, **options, &block)

          self
        end

        def remove_alias(name)
          @aliases.delete name
        end

        # Adds a reference.
        #
        #  t.references(:user)
        #  t.belongs_to(:supplier)
        #
        # See {connection.add_reference}[rdoc-ref:SchemaStatements#add_reference] for details of the options you can use.
        def references(*args, **options)
          args.each do |ref_name|
            ActiveRecord::ConnectionAdapters::ReferenceDefinition.new(ref_name, **options).add_to(self)
          end
        end

        alias :belongs_to :references

        # Appends <tt>:datetime</tt> columns <tt>:created_at</tt> and
        # <tt>:updated_at</tt> to the table. See {connection.add_timestamps}[rdoc-ref:SchemaStatements#add_timestamps]
        #
        #   t.timestamps
        def timestamps(**options)
          column(:created_at, :datetime, **options)
          column(:updated_at, :datetime, **options)
        end

        private

        # force empty states to prevent "Name is static for an open table" error.
        def state
          nil
        end

        def transform_mappings!(mappings)
          return unless mappings['properties'].present?

          mappings['properties'].each do |name, attributes|
            self.mapping(name, attributes.delete('type'), **attributes)
          end
        end

        def transform_settings!(settings)
          # exclude settings, that are provided through the API but are not part of the index-settings
          settings
            .with_indifferent_access
            .each { |name, value|
              # don't transform ignored names
              next if ActiveRecord::ConnectionAdapters::Elasticsearch::TableSettingDefinition.match_ignore_names?(name)

              self.setting(name, value)
            }
        end

        def transform_aliases!(aliases)
          aliases.each do |name, attributes|
            self.alias(name, **attributes)
          end
        end
      end
    end
  end
end
