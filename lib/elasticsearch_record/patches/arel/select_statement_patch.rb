# frozen_string_literal: true

require 'arel/nodes/select_statement'

module ElasticsearchRecord
  module Patches
    module Arel
      module SelectStatementPatch
        def configure
          @configure
        end

        def configure=(value)
          @configure = value
        end

        def initialize_copy(other)
          super
          @configure  = @configure&.deep_dup
        end

        def hash
          [super, @configure].hash
        end

        def eql?(other)
          super && configure == other.configure
        end
      end
    end
  end
end

# include once only!
::Arel::Nodes::SelectStatement.include(ElasticsearchRecord::Patches::Arel::SelectStatementPatch) unless ::Arel::Nodes::SelectStatement.included_modules.include?(ElasticsearchRecord::Patches::Arel::SelectStatementPatch)