module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      module Type # :nodoc:
        class Nested < ActiveRecord::Type::Value

          def type
            :nested
          end

          private

          # cast value
          def cast_value(value)
            value.to_h
          end
        end
      end
    end
  end
end