# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      module ColumnMethods
        extend ActiveSupport::Concern

        included do
          # see @ ::ActiveRecord::ConnectionAdapters::ElasticsearchAdapter::NATIVE_DATABASE_TYPES.keys
          define_column_methods :string, :blob, :datetime, :bigint, :json, :binary, :boolean, :keyword,
                                :constant_keyword, :wildcard, :long, :integer, :short, :byte, :double, :float,
                                :half_float, :scaled_float, :unsigned_long, :date, :object, :flattened, :nested,
                                :integer_range, :float_range, :long_range, :double_range, :date_range, :ip_range,
                                :ip, :version, :text
        end

        class_methods do
          def define_column_methods(*column_types)
            # :nodoc:
            column_types.each do |column_type|
              module_eval <<-RUBY, __FILE__, __LINE__ + 1
              def #{column_type}(*names, **options)
                raise ArgumentError, "Missing column name(s) for #{column_type}" if names.empty?
                names.each { |name| column(name, :#{column_type}, **options) }
              end
              RUBY
            end
          end

          private :define_column_methods
        end
      end
    end
  end
end
