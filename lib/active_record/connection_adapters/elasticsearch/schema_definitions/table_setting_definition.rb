# frozen_string_literal: true

require 'active_record/connection_adapters/elasticsearch/schema_definitions/validation_methods'

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class TableSettingDefinition
        include ValidationMethods

        # exclude settings, that are provided through the API but are not part of the index-settings
        INVALID_NAMES = [:provided_name, :creation_date, :uuid, :version].freeze

        # available setting names
        # - see @ https://www.elastic.co/guide/en/elasticsearch/reference/current/index-modules.html#index-modules-settings
        # toDo: finish definitions and uncomment validate!
        STATIC_NAMES  = [:number_of_routing_shards, :codec, :routing_partition_size].freeze
        DYNAMIC_NAMES = [:number_of_replicas, :auto_expand_replicas, :"search.idle.after", :refresh_interval, :max_result_window, :hidden].freeze
        NAMES         = (STATIC_NAMES + DYNAMIC_NAMES).freeze

        attr_accessor :name
        attr_accessor :value

        def initialize(name, value)
          @name  = name.to_sym
          @value = value
        end

        def static?
          STATIC_NAMES.include?(name)
        end

        def dynamic?
          DYNAMIC_NAMES.include?(name)
        end

        private

        # validate this mapping through the +#validate?+ method.
        def validate!
          # @_valid = NAMES.include?(name)
          @_valid = true
        end
      end
    end
  end
end
