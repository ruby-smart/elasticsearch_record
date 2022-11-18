# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      # this class is totally refactored from the original and acts here as "wrapper"
      # - to support rails backwards compatibility on the +#schema_creation+ method
      class SchemaCreation # :nodoc:

        attr_reader :connection

        def initialize(connection)
          @connection = connection
        end

        def accept(o)
          visitor.dispatch_as(:simple) do
            visitor.compile(o)
          end
        end

        private

        def visitor
          @visitor ||= connection.visitor
        end
      end
    end
  end
end
