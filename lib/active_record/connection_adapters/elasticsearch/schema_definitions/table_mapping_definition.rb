# frozen_string_literal: true

require 'active_record/connection_adapters/elasticsearch/schema_definitions/validation_methods'

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class TableMappingDefinition
        include ValidationMethods

        # available mapping properties
        # - see @ https://www.elastic.co/guide/en/elasticsearch/reference/current/mapping-params.html
        ATTRIBUTES = [:analyzer, :coerce, :copy_to, :doc_values, :dynamic, :eager_global_ordinals, :enabled,
                      :fielddata, :fields, :format, :ignore_above, :ignore_malformed, :index_options, :index_phrases,
                      :index_prefixes, :index, :meta, :normalizer, :norms, :null_value, :position_increment_gap,
                      :properties, :search_analyzer, :similarity, :subobjects, :store, :term_vector].freeze

        attr_accessor :name
        attr_accessor :type
        attr_accessor :attributes

        # build attribute related instance methods
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

        # sets the default value (alias for null_value)
        alias_method :default=, :null_value=
        alias_method :default, :null_value

        ####################
        # INSTANCE METHODS #
        ####################

        def initialize(name, type, attributes)
          @name       = name.to_sym
          @attributes = {}
          @type       = nil

          # IMPORTANT: must be set before setting the type!
          _assign_attributes(attributes)
          _assign_type(type)
        end

        def comment
          _nested_get(:meta, 'comment')
        end

        def comment=(value)
          # important: meta-values can only be strings!
          _nested_set(:meta, 'comment', value.to_s)
        end

        # backwards compatibility
        def primary_key
          _nested_get(:meta, 'primary_key')
        end

        alias_method :primary_key?, :primary_key

        def primary_key=(value)
          # important: meta-values can only be strings!
          _nested_set(:meta, 'primary_key', value ? 'true' : nil)
        end

        # restrict meta by conditional cases.
        # see @ https://www.elastic.co/guide/en/elasticsearch/reference/current/mapping-field-meta.html
        def meta=(value)
          return invalid!("attribute 'meta' is not a hash") unless value.is_a?(Hash)
          return invalid!("attribute 'meta' enforces at most 5 entries") if value.length > 5
          return invalid!("attribute 'meta' has a key with more then 20 chars") if value.keys.any? { |key| key.length > 20 }
          return invalid!("attribute 'meta' is not supported on object or nested fields") if [:object, :nested].include?(type)

          # allow only strings
          vkey = value.keys.detect { |key| !value[key].is_a?(String) }
          return invalid!("attribute 'meta' has a key '#{vkey}' with a none string value") if vkey.present?

          @attributes[:meta] = value
        end

        private

        # validate this mapping through the +#validate?+ method.
        def validate!
          if (inv_attrs = (attributes.keys - ATTRIBUTES)).present?
            return invalid!("invalid attributes: #{inv_attrs.join(', ')}")
          end

          @_valid = true
        end

        def _nested_set(attr, key, value)
          values = self.send(attr).presence || {}

          if value.nil?
            values.delete(key)
          else
            values[key] = value
          end
          self.send("#{attr}=", values)
        end

        def _nested_get(attr, key)
          values = self.send(attr).presence || {}
          values[key]
        end

        def _assign_attributes(attributes)
          attributes.each do |key, value|
            send("#{key}=", value)
          end
        end

        def _assign_type(type)
          # fallback for possible empty type
          type ||= (properties.present? ? :object : :nested)

          # check and transform possible alias types
          if ActiveRecord::ConnectionAdapters::ElasticsearchAdapter::NATIVE_DATABASE_TYPES.key?(type)
            type = ActiveRecord::ConnectionAdapters::ElasticsearchAdapter::NATIVE_DATABASE_TYPES[type][:name]
          end

          @type = type.to_sym
        end
      end
    end
  end
end
