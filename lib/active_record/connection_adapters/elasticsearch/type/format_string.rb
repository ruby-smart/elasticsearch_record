module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      module Type # :nodoc:
        class FormatString < ActiveRecord::Type::String
          attr_reader :format

          def initialize(**args)
            @format = args.delete(:format).presence || /.*/
            super
          end

          def type
            :format_string
          end

          private

          def cast_value(value)
            return value unless ::String === value
            return '' unless value.match(format)
            value
          end
        end
      end
    end
  end
end