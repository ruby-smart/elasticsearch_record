# frozen_string_literal: true

require 'active_record/connection_adapters/elasticsearch/schema_definitions/table_definition'

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class CloneTableDefinition < TableDefinition

        attr_reader :target

        def initialize(conn, name, target, settings: nil, aliases: nil, **opts)
          super(conn, name, **opts)

          @target   = target
          @settings = HashWithIndifferentAccess.new
          @aliases  = HashWithIndifferentAccess.new

          # before assigning new settings, we need to resolve some defaults
          assign_default_clone_settings!

          transform_settings!(settings) if settings.present?
          transform_aliases!(aliases) if aliases.present?
        end

        # returns an array with all +TableSettingDefinition+.
        # @return [Array]
        def settings
          @settings.values
        end

        # returns an array with all +TableAliasDefinition+.
        # @return [Array]
        def aliases
          @aliases.values
        end

        ######################
        # DEFINITION METHODS #
        ######################

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

        private

        def assign_default_clone_settings!
          settings = table_settings(name)
          setting('index.number_of_shards', (settings.dig('index.number_of_shards') || 1))
          setting('index.number_of_replicas', (settings.dig('index.number_of_replicas') || 0))
        end

        def _before_exec
          block_table(self.name, :write)
        end

        def _after_exec
          unblock_table(self.name, :write)
        end

        alias :_rescue_exec :_after_exec

        def _exec
          execute(schema_creation.accept(self), 'CLONE TABLE').dig('acknowledged')
        end

        # force empty states to prevent "Name is static for an open table" error.
        def state
          nil
        end
      end
    end
  end
end
