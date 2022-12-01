# frozen_string_literal: true

require 'active_record/connection_adapters/abstract/schema_definitions'
require 'active_record/connection_adapters/elasticsearch/schema_definitions/table_definition'

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class UpdateTableDefinition < TableDefinition

        attr_reader :definitions

        # defines which definitions can be executed composite
        COMPOSITE_DEFINITIONS = [
          AddMappingDefinition,
          ChangeMappingDefinition,

          AddSettingDefinition,
          DeleteAliasDefinition
        ].freeze

        def add_mapping(name, type, if_not_exists: false, **options, &block)
          return if if_not_exists && mapping_exists?(self.name, name, type)

          define! AddMappingDefinition, new_mapping_definition(name, type, **options, &block)
        end

        alias :add_column :add_mapping
        alias :mapping :add_mapping
        alias :column :add_mapping

        def change_mapping(name, type, if_exists: false, **options, &block)
          return if if_exists && !mapping_exists?(self.name, name, type)

          define! ChangeMappingDefinition, new_mapping_definition(name, type, **options, &block)
        end

        alias :change_column :change_mapping
        alias :change :change_mapping

        def change_mapping_meta(name, **options)
          mapping = table_mappings(self.name).dig('properties', name.to_s)
          raise ArgumentError, "you cannot change the 'meta' parameter for an unknown mapping '#{name}'" if mapping.blank?

          # resolve existing meta & merge with new
          meta = (mapping['meta'] || {}).merge(options)

          define! ChangeMappingDefinition, new_mapping_definition(name, mapping['type'], meta: meta)
        end

        def change_mapping_attributes(name, **options, &block)
          mapping = table_mappings(self.name).dig('properties', name.to_s)
          raise ArgumentError, "you cannot change parameters for an unknown mapping '#{name}'" if mapping.blank?

          options = mapping.with_indifferent_access.except(:type).merge(options) if options.present?

          define! ChangeMappingDefinition, new_mapping_definition(name, mapping['type'], **options, &block)
        end
        alias :change_mapping_attribute :change_mapping_attributes

        def add_setting(name, value, if_not_exists: false, **options, &block)
          return if if_not_exists && setting_exists?(self.name, name)

          define! AddSettingDefinition, new_setting_definition(name, value, **options, &block)
        end

        def change_setting(name, value, if_exists: false, **options, &block)
          return if if_exists && !setting_exists?(self.name, name)

          define! ChangeSettingDefinition, new_setting_definition(name, value, **options, &block)
        end

        def delete_setting(name, if_exists: false, **options, &block)
          return if if_exists && !setting_exists?(self.name, name)

          define! DeleteSettingDefinition, new_setting_definition(name, nil, **options, &block)
        end

        def add_alias(name, if_not_exists: false, **options, &block)
          return if if_not_exists && alias_exists?(self.name, name)

          define! AddAliasDefinition, new_alias_definition(name, **options, &block)
        end

        def change_alias(name, if_exists: false, **options, &block)
          return if if_exists && !alias_exists?(self.name, name)

          define! ChangeAliasDefinition, new_alias_definition(name, **options, &block)
        end

        def delete_alias(name, if_exists: false, **, &block)
          return if if_exists && !alias_exists?(self.name, name)

          define! DeleteAliasDefinition, new_alias_definition(name, &block)
        end

        # Appends <tt>:datetime</tt> columns <tt>:created_at</tt> and
        # <tt>:updated_at</tt> to the table. See {connection.add_timestamps}[rdoc-ref:SchemaStatements#add_timestamps]
        #
        #   t.timestamps
        def timestamps(**options)
          add_mapping(:created_at, :datetime, if_not_exists: true, **options)
          add_mapping(:updated_at, :datetime, if_not_exists: true, **options)
        end

        private

        def define!(klass, item)
          @definitions        ||= {}
          @definitions[klass] ||= []
          @definitions[klass] << item
        end

        def _before_assign
          # check, if the table should be closed before executing the queries
          close_table(self.name) if _toggle_table_status?

          # reset table state
          clear_state!
        end

        def _after_assign
          # run the same content as +_after_exec+, but only if the assignment failed
          _after_exec if failed?
        end

        def _after_exec
          # reopen the table again
          open_table(self.name) if _toggle_table_status?

          # reset table state
          clear_state!
        end

        def _toggle_table_status?
          @toggle_table_status = (force? && state[:status] == 'open') if @toggle_table_status.nil?

          @toggle_table_status
        end

        def _exec
          return unless definitions.any?

          # check, if the table should be closed before executing the queries
          close_table(self.name) if opts[:close] == true

          definitions.each do |klass, items|
            # check if the provided definition klass is a composite definition
            executable_definitions = if COMPOSITE_DEFINITIONS.include?(klass)
                                       [InterlacedUpdateTableDefinition.new(name, klass.new(items))]
                                     else
                                       items.map { |d|
                                         InterlacedUpdateTableDefinition.new(name, klass.new(d))
                                       }
                                     end

            executable_definitions.each do |ed|
              execute(schema_creation.accept(ed), _to_composite_log(klass))
            end
          end

          open_table(self.name) if opts[:close] == true

          # cleanup definitions
          @definitions = {}
        end

        def _to_composite_log(klass)
          klass.name.demodulize.underscore.gsub(/_definition/, '').gsub(/_/, ' ').upcase
        end
      end
    end
  end
end
