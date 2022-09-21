module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      module Type # :nodoc:
        class Range < MulticastValue

          def type
            "range_#{nested_type.type}".to_sym
          end

          private

          def cast_value(value)
            return (0..0) unless value.is_a?(Hash)
            # check for existing gte & lte

            min_value = if value['gte']
                          value['gte']
                        elsif value['gt']
                          value['gt'] + 1
                        else
                          nil
                        end

            max_value = if value['lte']
                          value['lte']
                        elsif value['lt']
                          value['lt'] - 1
                        else
                          nil
                        end

            return (0..0) if min_value.nil? || max_value.nil?

            # build & return range
            (min_value..max_value)
          end
        end
      end
    end
  end
end