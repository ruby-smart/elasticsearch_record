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
          options.extract!(:settings, :mappings, :aliases, :force, :strict)
        end

        def initialize(conn, name, settings: nil, mappings: nil, aliases: nil, **opts)
          @conn = conn
          @name = name
          @opts = opts

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
        def mapping(name, type, force: false, **attributes, &block)
          raise ArgumentError, "you cannot define an already defined mapping '#{name}'!" if @mappings.key?(name) && !force?(force)

          # build new mapping
          mapping = new_mapping_definition(name, type, attributes)
          block.call(mapping) if block_given?

          raise ArgumentError, "you cannot define an invalid mapping '#{name}' (#{mapping.validation_errors.join(', ')})!" if strict? && !mapping.valid?

          @mappings[name] = mapping

          self
        end

        # provide backwards compatibility to columns
        alias column mapping

        def remove_mapping(name)
          @mappings.delete(name)
        end

        # provide backwards compatibility to columns
        alias remove_column remove_mapping

        def setting(name, value, force: false, **, &block)
          raise ArgumentError, "you cannot define an already defined setting '#{name}'!" if @settings.key?(name) && !force?(force)

          # create new setting
          setting = new_setting_definition(name, value)
          block.call(setting) if block_given?

          raise ArgumentError, "you cannot define an invalid setting '#{name}' (#{setting.validation_errors.join(', ')})!" if strict? && !setting.valid?

          @settings[name] = setting

          self
        end

        def remove_setting(name)
          @settings.delete name
        end

        # we can use +alias+ here, since the instance method is not a reserved keyword!

        def alias(name, force: false, **attributes, &block)
          raise ArgumentError, "you cannot define an already defined alias '#{name}'." if @aliases.key?(name) && !force?(force)

          # create new alias
          tbl_alias = new_alias_definition(name, attributes)
          block.call(tbl_alias) if block_given?

          raise ArgumentError, "you cannot define an invalid alias '#{tbl_alias}' (#{tbl_alias.validation_errors.join(', ')})!" if strict? && !tbl_alias.valid?

          @aliases[name] = tbl_alias

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

        def new_mapping_definition(name, type, attributes)
          TableMappingDefinition.new(name, type, attributes)
        end

        def new_alias_definition(name, attributes)
          TableAliasDefinition.new(name, attributes)
        end

        def new_setting_definition(name, value)
          TableSettingDefinition.new(name, value)
        end

        # Appends <tt>:datetime</tt> columns <tt>:created_at</tt> and
        # <tt>:updated_at</tt> to the table. See {connection.add_timestamps}[rdoc-ref:SchemaStatements#add_timestamps]
        #
        #   t.timestamps
        def timestamps(**options)
          column(:created_at, :datetime, **options)
          column(:updated_at, :datetime, **options)
        end

        private

        def force?(fallback)
          opts[:force] || fallback
        end

        def strict?
          opts.fetch(:strict, true)
        end

        def transform_mappings!(mappings)
          mappings.with_indifferent_access[:properties].each do |name, attributes|
            self.mapping(name, attributes.delete(:type), **attributes)
          end
        end

        def transform_settings!(settings)
          # exclude settings, that are provided through the API but are not part of the index-settings
          settings
            .with_indifferent_access
            .except(*ActiveRecord::ConnectionAdapters::Elasticsearch::TableSettingDefinition::INVALID_NAMES)
            .each do |name, value|
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
