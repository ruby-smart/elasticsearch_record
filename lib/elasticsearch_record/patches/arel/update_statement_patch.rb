# frozen_string_literal: true

require 'arel/nodes/update_statement'
require 'arel/nodes/delete_statement'

module ElasticsearchRecord
  module Patches
    module Arel
      module UpdateStatementPatch
        def self.included(base)
          base.send(:prepend, PrependMethods)
        end

        module PrependMethods
          def initialize_copy(other)
            super
            @configure  = @configure&.deep_dup
            @queries  = @queries&.clone
          end

          def hash
            [super, @configure, @queries].hash
          end

          def eql?(other)
            super && kind == other.kind && configure == other.configure && queries == other.queries
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

        def configure
          @configure
        end

        def configure=(value)
          @configure = value
        end
      end
    end
  end
end

# include once only!
::Arel::Nodes::UpdateStatement.include(ElasticsearchRecord::Patches::Arel::UpdateStatementPatch) unless ::Arel::Nodes::UpdateStatement.included_modules.include?(ElasticsearchRecord::Patches::Arel::UpdateStatementPatch)
::Arel::Nodes::DeleteStatement.include(ElasticsearchRecord::Patches::Arel::UpdateStatementPatch) unless ::Arel::Nodes::DeleteStatement.included_modules.include?(ElasticsearchRecord::Patches::Arel::UpdateStatementPatch)