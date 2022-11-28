# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      module ValidationMethods
        extend ActiveSupport::Concern

        included do
          def valid?
            validate! if @_valid.nil?

            @_valid
          end

          def validation_errors
            @validation_errors ||= []
          end

          private

          def validate!
            @_valid = true
          end

          def invalid!(message = nil)
            self.validation_errors << message if message.present?
            @_valid = false
          end
        end
      end
    end
  end
end
