module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      module Type # :nodoc:
        class Object < ActiveRecord::Type::Value
          attr_reader :cast_type, :default

          # creates a new object type which can be natively every value.
          # Providing a +cast+ will call the value with this method (or callback)
          # @param [nil, Symbol, String, Proc] cast - the cast type
          # @param [nil, Object] default
          # @param [Boolean] force - force value to be casted (used by the MulticastValue type) - (default: false)
          def initialize(cast: nil, default: nil, force: false, **)
            @cast_type = cast
            @default   = default
            @force     = force
          end

          def type
            :object
          end

          def forced?
            @force
          end

          private

          # cast value by provided cast_method
          def cast_value(value)
            case self.cast_type
            when Symbol, String
              value.public_send(self.cast_type) rescue default
            when Proc
              self.cast_type.(value) rescue default
            else
              value
            end
          end
        end
      end
    end
  end
end