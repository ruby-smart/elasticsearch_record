# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      module Quoting # :nodoc:
        extend ActiveSupport::Concern

        module ClassMethods # :nodoc:
          # since rails 7.2 identifier quoting is class-level & mandatory (the abstract
          # implementation raises a +NotImplementedError+). Elasticsearch fields & indices are
          # plain JSON keys - so they pass through unquoted.
          def quote_column_name(column_name)
            column_name.to_s
          end

          # Quotes the table (index) name. Defaults to column name quoting.
          def quote_table_name(table_name)
            quote_column_name(table_name)
          end
        end

        def quoted_true
          'true'
        end

        def quoted_false
          'false'
        end
      end
    end
  end
end
