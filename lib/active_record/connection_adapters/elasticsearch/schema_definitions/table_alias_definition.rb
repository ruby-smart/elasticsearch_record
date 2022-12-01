# frozen_string_literal: true

require 'active_model/validations'

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class TableAliasDefinition
        include AttributeMethods
        include ActiveModel::Validations

        # available alias properties
        # - see @ https://www.elastic.co/guide/en/elasticsearch/reference/current/indices-create-index.html#indices-create-api-request-body
        ATTRIBUTES = [:filter, :index_routing, :is_hidden, :is_write_index, :routing, :search_routing].freeze
        build_attribute_methods! *ATTRIBUTES

        # attributes
        attr_accessor :name
        attr_accessor :attributes

        # validations
        validates_presence_of :name
        validates_inclusion_of :__attributes_keys, in: ATTRIBUTES, allow_blank: true

        def initialize(name, attributes)
          self.name       = name.to_sym
          self.attributes = attributes.symbolize_keys
        end
      end
    end
  end
end
