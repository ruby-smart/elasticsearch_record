module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      module Type # :nodoc:
        class MulticastValue < ActiveRecord::Type::Value

          delegate :user_input_in_time_zone, to: :nested_type

          attr_reader :nested_type

          def initialize(nested_type: nil, **)
            @nested_type = nested_type || ActiveRecord::Type::Value.new
          end

          def type
            nested_type.type
          end

          # overwrites the default deserialize behaviour
          # @param [Object] value
          # @return [Object,nil] deserialized object
          def deserialize(value)
            cast(_deserialize(value))
          end

          private

          def _deserialize(value)
            # check for the special +object+ type which is forced to be casted
            return _deserialize_by_nested_type(value) if nested_type.type == :object

            if value.is_a?(Array)
              value.map { |val| _deserialize_by_nested_type(val) }
            elsif value.is_a?(Hash)
              value.reduce({}) { |m, (key, val)|
                m[key] = _deserialize_by_nested_type(val)
                m
              }
            else
              _deserialize_by_nested_type(value)
            end
          end

          # in some cases we cannot deserialize, since the ES-type don't match well with the provided value
          # but the result should be ok, as it is (e.g. 'Hash')...
          # so we rescue here with just the provided value
          def _deserialize_by_nested_type(value)
            nested_type.deserialize(value) rescue value
          end
        end
      end
    end
  end
end