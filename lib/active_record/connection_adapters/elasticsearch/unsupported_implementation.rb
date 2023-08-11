# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      module UnsupportedImplementation
        extend ActiveSupport::Concern

        class_methods do
          def define_unsupported_method(*method_names)
            method_names.each do |method_name|
              module_eval <<-RUBY, __FILE__, __LINE__ + 1
                def #{method_name}(*args)
                  raise NotImplementedError, "'##{method_name}' is originally defined by 'ActiveRecord::ConnectionAdapters' but is not supported by Elasticsearch. Choose a different solution to prevent the execution of this method!"
                end
              RUBY
            end
          end

          private :define_unsupported_method
        end
      end
    end
  end
end
