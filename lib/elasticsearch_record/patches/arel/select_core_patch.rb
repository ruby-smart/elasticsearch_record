# frozen_string_literal: true

require 'arel/nodes/select_core'

module ElasticsearchRecord
  module Patches
    module Arel
      module SelectCorePatch
        def self.included(base)
          base.send(:prepend, PrependMethods)
        end

        module PrependMethods
          def initialize_copy(other)
            super
            @kind    = @kind.clone if @kind
            @queries = @queries.clone if @queries
            @aggs    = @aggs.clone if @aggs
          end

          def hash
            [
              super, @kind, @queries, @aggs
            ].hash
          end

          def eql?(other)
            super &&
              self.kind == other.kind &&
              self.queries == other.queries &&
              self.aggs == other.aggs
          end
        end

        def kind
          @kind
        end

        def kind=(value)
          @kind = value
        end

        def queries
          @queries ||= []
        end

        def queries=(value)
          @queries = value
        end

        def aggs
          @aggs ||= []
        end

        def aggs=(value)
          @aggs = value
        end
      end
    end
  end
end

# include once only!
::Arel::Nodes::SelectCore.include(ElasticsearchRecord::Patches::Arel::SelectCorePatch) unless ::Arel::Nodes::SelectCore.included_modules.include?(ElasticsearchRecord::Patches::Arel::SelectCorePatch)