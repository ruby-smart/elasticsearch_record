# frozen_string_literal: true

require 'active_record/connection_adapters/elasticsearch/schema_definitions/table_alias_definition'
require 'active_record/connection_adapters/elasticsearch/schema_definitions/table_mapping_definition'
require 'active_record/connection_adapters/elasticsearch/schema_definitions/table_setting_definition'
require 'active_record/connection_adapters/elasticsearch/schema_definitions/column_methods'

# required to load related definitions
require 'active_record/connection_adapters/abstract/schema_definitions'

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class TableDefinition
        include ColumnMethods

        attr_reader :name
        attr_reader :opts

        def self.extract_table_options!(options)
          options.extract!(:settings, :mappings, :aliases, :force, :strict, :drop_invalid)
        end

        def initialize(conn, name, settings: nil, mappings: nil, aliases: nil, **opts)
          @conn = conn
          @name = name
          @opts = extract_opts!(opts)

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
        def mapping(name, type, force: false, **attributes)
          raise ArgumentError, "you can't define an already defined mapping '#{name}'." if @mappings.key?(name) && !force?(force)

          # create new mapping
          mapping         = new_mapping_definition(name, type, attributes)

          # add the mapping if it should not be validated or is valid
          @mappings[name] = mapping if !drop_invalid? || mapping.valid?

          self
        end

        # provide backwards compatibility to columns
        alias column mapping

        def remove_mapping(name)
          @mappings.delete(name)
        end

        # provide backwards compatibility to columns
        alias remove_column remove_mapping

        def setting(name, value, force: false, **)
          raise ArgumentError, "you can't define an already defined setting '#{name}'." if @settings.key?(name) && !force?(force)

          # create new setting
          setting         = new_setting_definition(name, value)

          # add the setting if it should not be validated or is valid
          @settings[name] = setting if !drop_invalid? || setting.valid?

          self
        end

        def remove_setting(name)
          @settings.delete name
        end

        def alias(name, force: false, **attributes)
          raise ArgumentError, "you can't define an already defined alias '#{name}'." if @aliases.key?(name) && !force?(force)

          # create new alias
          talias         = new_alias_definition(name, attributes)

          # add the _alias if it should not be validated or is valid
          @aliases[name] = talias if !drop_invalid? || talias.valid?

          self
        end

        def remove_alias(name)
          @aliases.delete name
        end

        # Adds a reference.
        #
        #  t.references(:user)
        #  t.belongs_to(:supplier, foreign_key: true)
        #  t.belongs_to(:supplier, foreign_key: true, type: :integer)
        #
        # See {connection.add_reference}[rdoc-ref:SchemaStatements#add_reference] for details of the options you can use.
        def references(*args, **options)
          args.each do |ref_name|
            ActiveRecord::ConnectionAdapters::ReferenceDefinition.new(ref_name, **options).add_to(self)
          end
        end

        alias :belongs_to :references

        def new_mapping_definition(name, type, attributes)
          TableMappingDefinition.new(name, type, attributes, **opts)
        end

        def new_alias_definition(name, attributes)
          TableAliasDefinition.new(name, attributes, **opts)
        end

        def new_setting_definition(name, value)
          TableSettingDefinition.new(name, value, **opts)
        end

        private

        def extract_opts!(options)
          options.extract!(:force, :strict, :drop_invalid)
        end

        def force?(fallback)
          opts[:force] || fallback
        end

        def strict?
          opts[:strict]
        end

        def drop_invalid?
          opts[:drop_invalid]
        end

        def transform_mappings!(mappings)
          # transform
          mappings = mappings.with_indifferent_access

          mappings[:properties].each do |name, attributes|
            self.mapping(name, attributes.delete(:type), **attributes)
          end
        end

        def transform_settings!(settings)
          settings.each do |name, value|
            self.setting(name, value)
          end
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
