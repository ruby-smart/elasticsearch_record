# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch

      class UnsupportedImplementationError < StandardError
        def initialize(method_name)
          super "Unsupported implementation of method: #{method_name}."
        end
      end

      module UnsupportedImplementation
        extend ActiveSupport::Concern

        class_methods do
          def define_unsupported_methods(*method_names)
            method_names.each do |method_name|
              module_eval <<-RUBY, __FILE__, __LINE__ + 1
                def #{method_name}(*args)
                  raise ActiveRecord::ConnectionAdapters::Elasticsearch::UnsupportedImplementationError, method_name
                end
              RUBY
            end
          end

          private :define_unsupported_methods
        end
      end
    end
  end
end
