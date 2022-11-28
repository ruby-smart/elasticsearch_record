# frozen_string_literal: true

require 'active_record/connection_adapters/elasticsearch/schema_definitions/validation_methods'

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class TableAliasDefinition
        include ValidationMethods

        # available alias properties
        # - see @ https://www.elastic.co/guide/en/elasticsearch/reference/current/indices-create-index.html#indices-create-api-request-body
        ATTRIBUTES = [:filter, :index_routing, :is_hidden, :is_write_index, :routing, :search_routing].freeze

        attr_accessor :name
        attr_accessor :attributes

        def initialize(name, attributes)
          @name       = name.to_sym
          @attributes = {}

          _assign_attributes(attributes)
        end

        ATTRIBUTES.each do |param_name|
          class_eval <<-CODE, __FILE__, __LINE__ + 1
          def #{param_name}
            @attributes[:#{param_name}]
          end

          def #{param_name}=(value)
            @attributes[:#{param_name}] = value
          end
          CODE
        end

        private

        # validate this mapping through the +#validate?+ method.
        def validate!
          if (inv_attrs = (attributes.keys - ATTRIBUTES)).present?
            return invalid!("invalid attributes: #{inv_attrs.join(', ')}")
          end

          @_valid = true
        end

        def _assign_attributes(attributes)
          attributes.each do |key, value|
            send("#{key}=", value)
          end
        end
      end
    end
  end
end
