# frozen_string_literal: true

require 'active_model/validations'

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class TableMetaDefinition
        include ActiveModel::Validations

        # attributes
        attr_accessor :name
        attr_accessor :value

        validates_presence_of :name

        def initialize(name, value)
          @name  = name.to_sym
          @value = value
        end
      end
    end
  end
end
