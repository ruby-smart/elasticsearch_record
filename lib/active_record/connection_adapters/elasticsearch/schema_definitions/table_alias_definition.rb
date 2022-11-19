# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class TableAliasDefinition
        # available alias properties
        # - see @ https://www.elastic.co/guide/en/elasticsearch/reference/current/indices-create-index.html#indices-create-api-request-body
        ATTRIBUTES = [:filter, :index_routing, :is_hidden, :is_write_index, :routing, :search_routing].freeze

        attr_accessor :name
        attr_accessor :attributes

        def initialize(name, attributes)
          @name       = name.to_sym
          @attributes = attributes.symbolize_keys
        end

        def valid?
          validate! if @_valid.nil?

          @_valid
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

        def validate!
          @_valid = (attributes.keys - ATTRIBUTES).blank?
        end
      end
    end
  end
end