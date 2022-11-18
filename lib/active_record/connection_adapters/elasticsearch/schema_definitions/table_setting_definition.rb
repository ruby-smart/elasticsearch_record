# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class TableSettingDefinition
        # available setting names
        # - see @ https://www.elastic.co/guide/en/elasticsearch/reference/current/index-modules.html#index-modules-settings
        # toDo: finish definitions and uncomment validate!
        STATIC_SETTING_NAMES  = [:number_of_routing_shards, :codec, :routing_partition_size].freeze
        DYNAMIC_SETTING_NAMES = [:number_of_replicas, :auto_expand_replicas, 'search.idle.after', :refresh_interval].freeze
        SETTING_NAMES         = (STATIC_SETTING_NAMES + DYNAMIC_SETTING_NAMES).freeze

        EXCLUDE_SETTING_NAMES = [:provided_name, :creation_date, :uuid, :version].freeze

        attr_accessor :name
        attr_accessor :value

        def initialize(name, value, strict: false, **)
          @name  = name.to_sym
          @value = value

          invalid! if strict && !valid?
        end

        def valid?
          validate! if @_valid.nil?

          @_valid
        end

        private

        def invalid!
          raise ArgumentError, "you can't define an invalid setting '#{name}'."
        end

        def validate!
          @_valid = !EXCLUDE_SETTING_NAMES.include?(name)
        end
      end
    end
  end
end
