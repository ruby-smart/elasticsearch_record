# frozen_string_literal: true

require 'active_record/connection_adapters/elasticsearch/schema_definitions/table_definition'

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class UpdateTableDefinition < TableDefinition

        attr_reader :definitions

        def initialize(*args)
          super

          @definitions = {}
          @exec        = true
        end

        # yields provided block with self to change the table and executes those queries
        def assign
          @exec = false
          yield self
          @exec = true
          exec!
        end

        def add_mapping(name, type, **options, &block)
          define! AddMappingDefinition, new_mapping_definition(name, type, **options, &block)
        end

        alias :add_column :add_mapping

        def exec!
          definitions.each do |klass, definitions|
            cdef = CompositeUpdateTableDefinition.new(name, klass.new(definitions))

            conn.execute(conn.schema_creation.accept(cdef), _to_composite_log(klass))
          end
        end

        private

        def composite_definitions
          definitions.group_by(&:class)
        end

        def define!(klass, definition)
          @definitions[klass] ||= []
          @definitions[klass] << definition

          exec! if exec?
        end

        def exec?
          @exec
        end

        def _to_composite_log(klass)
          klass.name.demodulize.underscore.gsub(/_definition/,'').gsub(/_/,' ').upcase
        end
      end
    end
  end
end
