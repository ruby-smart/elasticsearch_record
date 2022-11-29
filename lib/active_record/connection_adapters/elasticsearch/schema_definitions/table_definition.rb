# frozen_string_literal: true

require 'active_record/connection_adapters/elasticsearch/schema_definitions/table_alias_definition'
require 'active_record/connection_adapters/elasticsearch/schema_definitions/table_mapping_definition'
require 'active_record/connection_adapters/elasticsearch/schema_definitions/table_setting_definition'
require 'active_record/connection_adapters/elasticsearch/schema_definitions/column_methods'

# required to load related definitions
# - ActiveRecord::ConnectionAdapters::ReferenceDefinition
require 'active_record/connection_adapters/abstract/schema_definitions'

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class TableDefinition
        include ColumnMethods

        attr_reader :conn
        attr_reader :name
        attr_reader :opts

        def self.extract_table_options!(options)
          options.extract!(:settings, :mappings, :aliases, :force, :strict)
        end

        def initialize(conn, name, **opts)
          @conn = conn
          @name = name
          @opts = opts
        end

        private

        def new_mapping_definition(name, type, strict: true, **attributes, &block)
          mapping = TableMappingDefinition.new(name, type, attributes)
          block.call(mapping) if block_given?

          raise ArgumentError, "you cannot define an invalid mapping '#{name}' (#{mapping.error_messages})!" if strict?(strict) && !mapping.valid?

          mapping
        end

        alias :new_column_definition :new_mapping_definition

        def new_alias_definition(name, strict: true, **attributes, &block)
          # create new alias
          tbl_alias = TableAliasDefinition.new(name, attributes)
          block.call(tbl_alias) if block_given?

          raise ArgumentError, "you cannot define an invalid alias '#{tbl_alias}' (#{tbl_alias.error_messages})!" if strict?(strict) && !tbl_alias.valid?

          tbl_alias
        end

        def new_setting_definition(name, value, strict: true, **, &block)
          # create new setting
          setting = TableSettingDefinition.new(name, value).with_state(state)
          block.call(setting) if block_given?

          raise ArgumentError, "you cannot define an invalid setting '#{name}' (#{setting.error_messages})!" if strict?(strict) && !setting.valid?

          setting
        end

        # returns the state of the current table.
        def state
          @state ||= conn.table_state(name) rescue { status: 'missing', name: name }
        end

        def force?(fallback)
          opts[:force] || fallback
        end

        def strict?(strict = nil)
          opts.fetch(:strict, true) && strict != false
        end
      end
    end
  end
end
