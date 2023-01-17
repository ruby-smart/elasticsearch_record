# frozen_string_literal: true

require 'active_record/connection_adapters/elasticsearch/schema_definitions/table_definition'

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class CreateTableDefinition < TableDefinition
        def initialize(conn, name, settings: nil, mappings: nil, aliases: nil, metas: nil, **opts)
          super(conn, name, **opts)

          @settings = HashWithIndifferentAccess.new
          @mappings = HashWithIndifferentAccess.new
          @aliases  = HashWithIndifferentAccess.new
          @metas    = HashWithIndifferentAccess.new

          transform_settings!(settings) if settings.present?
          transform_mappings!(mappings) if mappings.present?
          transform_aliases!(aliases) if aliases.present?
          # PLEASE NOTE: metas are already provided through the mappings (['_meta']),
          # but this will support individually provided key<->values...
          transform_metas!(metas) if metas.present?
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

        # returns an array with all +TableMetaDefinition+.
        # @return [Array]
        def metas
          @metas.values
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

        # adds a new meta
        def meta(name, value, force: false, **options)
          raise ArgumentError, "you cannot define an already defined meta '#{name}'!" if @metas.key?(name) && !force?(force)

          @metas[name] = new_meta_definition(name, value, **options)

          self
        end

        def change_meta(name, value, **options)
          # simply force full overwrite
          meta(name, value, force: true, **options)
        end

        def remove_meta(name)
          @metas.delete(name)
        end

        # adds a new mapping
        def mapping(name, type, if_not_exists: false, force: false, **options, &block)
          return if if_not_exists && @mappings.key?(name)
          raise ArgumentError, "you cannot define an already defined mapping '#{name}'!" if @mappings.key?(name) && !force?(force)

          mapping = new_mapping_definition(name, type, **options, &block)
          @mappings[name] = mapping

          # check if the mapping is assigned as primary_key
          if mapping.primary_key?
            meta :primary_key, mapping.name
            meta(:auto_increment, mapping.auto_increment) if mapping.auto_increment?
          end

          self
        end

        # provide backwards compatibility to columns
        alias :column :mapping
        alias :add_mapping :mapping
        alias :add_column :mapping

        def change_mapping(name, type, if_exists: false, **options, &block)
          return if if_exists && !@mappings.key?(name)

          raise ArgumentError, "you cannot change an unknown mapping '#{name}'" unless @mappings.key?(name)

          mapping(name, type, force: true, **options, &block)
        end

        alias :change_column :change_mapping
        alias :change :change_mapping

        def change_mapping_meta(name, **options)
          raise ArgumentError, "you cannot change the 'meta' parameter for an unknown mapping '#{name}'" unless @mappings.key?(name)

          # merge mapping options
          opts = @mappings[name].attributes
          opts['meta'] = @mappings[name].meta.merge(options)

          mapping(name, @mappings[name].type, force: true, **opts)
        end

        def change_mapping_attributes(name, if_exists: false, **options, &block)
          return if if_exists && !@mappings.key?(name)

          raise ArgumentError, "you cannot change an unknown mapping '#{name}'" unless @mappings.key?(name)

          # merge mapping attributes
          opts = @mappings[name].attributes.merge(options)

          mapping(name, @mappings[name].type, force: true, **opts, &block)
        end

        def remove_mapping(name)
          @mappings.delete(name)
        end

        # provide backwards compatibility to columns
        alias :remove_column :remove_mapping

        def setting(name, value, if_not_exists: false, force: false, **options, &block)
          return if if_not_exists && @settings.key?(name)
          raise ArgumentError, "you cannot define an already defined setting '#{name}'!" if @settings.key?(name) && !force?(force)

          @settings[name] = new_setting_definition(name, value, **options, &block)

          self
        end

        def change_setting(name, value, if_exists: false, **options, &block)
          return if if_exists && !@settings.key?(name)

          # simply force full overwrite
          setting(name, value, force: true, **options, &block)
        end

        def remove_setting(name)
          @settings.delete name
        end

        def add_alias(name, if_not_exists: false, force: false, **options, &block)
          return if if_not_exists && @aliases.key?(name)
          raise ArgumentError, "you cannot define an already defined alias '#{name}'." if @aliases.key?(name) && !force?(force)

          @aliases[name] = new_alias_definition(name, **options, &block)

          self
        end

        def change_alias(name, if_exists: false, **options, &block)
          return if if_exists && !@aliases.key?(name)

          # simply force full overwrite
          add_alias(name, force: true, **options, &block)
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

        def _exec
          execute(schema_creation.accept(self), 'CREATE TABLE').dig('acknowledged')
        end

        # force empty states to prevent "Name is static for an open table" error.
        def state
          nil
        end

        def transform_mappings!(mappings)
          # transform +_meta+ mappings
          if mappings['_meta'].present?
            mappings['_meta'].each do |name, value|
              self.meta(name, value, force: true)
            end
          end

          # transform properties (=columns)
          if mappings['properties'].present?
            mappings['properties'].each do |name, attributes|
              self.mapping(name, attributes.delete('type'), force: true, **attributes)
            end
          elsif mappings.present? && mappings.values[0].is_a?(Hash)
            # raw settings where provided with just (key => attributes)
            mappings.each do |name, attributes|
              self.mapping(name, attributes.delete('type'), force: true, **attributes)
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

              self.setting(name, value, force: true)
            }
        end

        def transform_aliases!(aliases)
          aliases.each do |name, attributes|
            self.alias(name, force: true, **attributes)
          end
        end

        def transform_metas!(metas)
          metas.each do |name, value|
            self.meta(name, value, force: true)
          end
        end
      end
    end
  end
end
