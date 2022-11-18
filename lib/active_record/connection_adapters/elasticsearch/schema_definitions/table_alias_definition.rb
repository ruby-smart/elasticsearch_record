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

        def initialize(name, attributes, strict: false, **)
          @name       = name.to_sym
          @attributes = attributes

          invalid! if strict && !valid?
        end

        ATTRIBUTES.each do |attr|
          class_eval <<-CODE, __FILE__, __LINE__ + 1
          def #{attr}
            @attributes[:#{attr}]
          end

          def #{attr}=(value)
            @attributes[:#{attr}] = value
          end
          CODE
        end

        def valid?
          validate! if @_valid.nil?

          @_valid
        end

        private

        def invalid!
          raise ArgumentError, "you can't define invalid attributes '#{(attributes.keys - ATTRIBUTES).join(', ')}' for TableAlias!"
        end

        def validate!
          @_valid = (attributes.keys - ATTRIBUTES).blank?
        end
      end
    end
  end
end
