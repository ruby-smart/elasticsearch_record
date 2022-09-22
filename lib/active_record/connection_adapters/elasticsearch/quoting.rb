# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      module Quoting # :nodoc:
        # Quotes the column value to help prevent
        def quote(value)
          case value
            # those values do not need to be quoted
          when BigDecimal, Numeric, nil, true, false then value
          when ActiveSupport::Duration then value.to_i
          when Array then value.map { |val| quote(val) }
          when Hash then value.transform_values { |value| quote(value) }
          else
            super
          end
        end

        def quoted_true
          true
        end

        def unquoted_true
          true
        end

        def quoted_false
          false
        end

        def unquoted_false
          false
        end
      end
    end
  end
end
