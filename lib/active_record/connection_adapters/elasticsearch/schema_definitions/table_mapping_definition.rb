# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class TableMappingDefinition
        # available mapping properties
        # - see @ https://www.elastic.co/guide/en/elasticsearch/reference/current/mapping-params.html
        ATTRIBUTES = [:analyzer, :coerce, :copy_to, :doc_values, :dynamic, :eager_global_ordinals, :enabled,
                      :fielddata, :fields, :format, :ignore_above, :ignore_malformed, :index_options, :index_phrases,
                      :index_prefixes, :index, :meta, :normalizer, :norms, :null_value, :position_increment_gap,
                      :properties, :search_analyzer, :similarity, :subobjects, :store, :term_vector].freeze

        attr_accessor :name
        attr_accessor :type
        attr_writer :attributes

        def initialize(name, type, attributes, strict: false, **)
          @name       = name.to_sym
          @type       = type.to_sym
          @attributes = attributes

          invalid! if strict && !valid?
        end

        def attributes
          @attributes.merge(type: type)
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

        # sets the default value (alias for null_value)
        alias_method :default=, :null_value=
        alias_method :default, :null_value

        def valid?
          validate! if @_valid.nil?

          @_valid
        end

        private

        def invalid!
          raise ArgumentError, "you can't define invalid attributes '#{(attributes.keys - ATTRIBUTES).join(', ')}' for TableMapping!"
        end

        def validate!
          @_valid = (attributes.keys - ATTRIBUTES).blank?
        end
      end
    end
  end
end
