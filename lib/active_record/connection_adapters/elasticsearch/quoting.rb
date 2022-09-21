# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      module Quoting # :nodoc:
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
