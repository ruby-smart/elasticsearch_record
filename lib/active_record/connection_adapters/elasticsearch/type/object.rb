module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      module Type # :nodoc:
        class Object < ActiveRecord::Type::Value
          def type
            :object
          end

          private

          # cast value by provided cast_method
          def cast_value(value)
            value.to_h
          end
        end
      end
    end
  end
end