# frozen_string_literal: true

# required to load related definitions
# - ActiveRecord::ConnectionAdapters::ReferenceDefinition
require 'active_record/connection_adapters/abstract/schema_definitions'

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class TableDefinition
        include ColumnMethods

        delegate :execute, :schema_creation,
                 :column_exists?, :mapping_exists?, :meta_exists?, :setting_exists?, :alias_exists?,
                 :close_table, :open_table, :block_table, :unblock_table,
                 :table_mappings, :table_metas, :table_settings, to: :conn

        attr_reader :conn
        attr_reader :name
        attr_reader :opts

        def initialize(conn, name, **opts)
          @conn   = conn
          @name   = name
          @opts   = opts
          @failed = false
        end

        # yields provided block with self to change the table and collect table information
        # returns self, to chain this method
        def assign
          # if before assign fails, we don't want to continue yielding!
          _before_assign

          begin
            yield self
          rescue => e
            @failed = false
            _rescue_assign
            raise e
          end

          _after_assign
        end

        def exec!
          # if before exec fails, we don't want to continue with execution!
          _before_exec

          begin
            _exec
          rescue => e
            @failed = false
            _rescue_exec
            raise e
          end

          _after_exec
        end

        def failed?
          @failed
        end

        private

        def _before_assign
          true
        end

        def _after_assign
          true
        end

        def _rescue_assign
          true
        end

        def _before_exec
          true
        end

        def _after_exec
          true
        end

        def _rescue_exec
          true
        end

        def _exec
          raise ArgumentError, "you cannot execute a TableDefinition directly - use 'CreateTableDefinition' or 'UpdateTableDefinition' instead!"
        end

        def new_meta_definition(name, value, strict: false, **)
          meta = TableMetaDefinition.new(name, value)

          raise ArgumentError, "you cannot define an invalid meta '#{name}' (#{meta.error_messages})!" if strict?(strict) && !meta.valid?

          meta
        end

        def new_mapping_definition(name, type, strict: false, **attributes, &block)
          mapping = TableMappingDefinition.new(name, type, attributes)
          block.call(mapping) if block_given?

          raise ArgumentError, "you cannot define an invalid mapping '#{name}' (#{mapping.error_messages})!" if strict?(strict) && !mapping.valid?

          mapping
        end

        alias :new_column_definition :new_mapping_definition

        def new_alias_definition(name, strict: false, **attributes, &block)
          # create new alias
          tbl_alias = TableAliasDefinition.new(name, attributes)
          block.call(tbl_alias) if block_given?

          raise ArgumentError, "you cannot define an invalid alias '#{tbl_alias}' (#{tbl_alias.error_messages})!" if strict?(strict) && !tbl_alias.valid?

          tbl_alias
        end

        def new_setting_definition(name, value, strict: false, **, &block)
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

        def clear_state!
          @state = nil
        end

        def force?(fallback = false)
          opts.fetch(:force, fallback)
        end

        def strict?(strict = nil)
          opts.fetch(:strict, false) || strict
        end

        def transform_mappings!(mappings)
          # transform +_meta+ mappings
          if mappings['_meta'].present?
            mappings['_meta'].each do |name, value|
              self.meta(name, value)
            end
          end

          # transform properties (=columns)
          if mappings['properties'].present?
            mappings['properties'].each do |name, attributes|
              self.mapping(name, attributes.delete('type'), **attributes)
            end
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
