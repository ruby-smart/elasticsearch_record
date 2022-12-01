# frozen_string_literal: true

require 'active_model/validations'

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class TableMappingDefinition
        include AttributeMethods
        include ActiveModel::Validations

        # available mapping properties
        # - see @ https://www.elastic.co/guide/en/elasticsearch/reference/current/mapping-params.html
        ATTRIBUTES = [:analyzer, :coerce, :copy_to, :doc_values, :dynamic, :eager_global_ordinals, :enabled,
                      :fielddata, :fields, :format, :ignore_above, :ignore_malformed, :index_options, :index_phrases,
                      :index_prefixes, :index, :meta, :normalizer, :norms, :null_value, :position_increment_gap,
                      :properties, :search_analyzer, :similarity, :subobjects, :store, :term_vector].freeze

        build_attribute_methods! *ATTRIBUTES

        # attributes
        attr_accessor :name
        attr_accessor :type
        attr_accessor :attributes

        # validations
        validates_presence_of :name
        validates_presence_of :type
        validates_inclusion_of :__attributes_keys, in: ATTRIBUTES, allow_blank: true

        # disable validation for meta attribute - maybe future updates of Elasticsearch have other restrictions.
        # To not be hooked on those possible changes we
        #validate :_validate_meta

        # sets the default value (alias for null_value)
        alias_method :default=, :null_value=
        alias_method :default, :null_value

        ####################
        # INSTANCE METHODS #
        ####################

        def initialize(name, type, attributes)
          @name       = name.to_sym
          @attributes = attributes.symbolize_keys

          @type = _resolve_type(type)
        end

        # comment is handled as nested key from 'meta' attribute
        def comment
          __get_nested(:meta, :comment)
        end

        def comment=(value)
          # important: meta-values can only be strings!
          __set_nested(:meta, :comment, value.to_s)
        end

        def primary_key
          __get_nested(:meta, :primary_key) == 'true'
        end

        alias_method :primary_key?, :primary_key

        # defines this mapping as a primary key
        def primary_key=(value)
          # important: meta-values can only be strings!
          __set_nested(:meta, :primary_key, value ? 'true' : nil)
        end

        def meta=(value)
          if value.nil?
            __remove_attribute(:meta)
          else
            __set_attribute(:meta, value.compact)
          end
        end

        private

        # resolves the provided type.
        # prevents to set a nil type (sets +:object+ or +:nested+ - depends on existing properties)
        # @return [Symbol, nil]
        def _resolve_type(type)
          return type.to_sym if type.present?

          # fallback for possible empty type
          (properties.present? ? :object : :nested)
        end

        # validates metadata restrictions
        def _validate_meta
          return true if meta.nil?

          return invalid!("'meta' must be a hash", :attributes) unless meta.is_a?(Hash)
          return invalid!("'meta' enforces at most 5 entries", :attributes) if meta.length > 5
          return invalid!("'meta' has a key with more then 20 chars", :attributes) if meta.keys.any? { |key| key.length > 20 }
          return invalid!("'meta' is not supported on object or nested types", :attributes) if [:object, :nested].include?(type)

          # allow only strings
          vkey = meta.keys.detect { |key| !meta[key].is_a?(String) }
          return invalid!("'meta' has a key '#{vkey}' with a none string value", :attributes) if vkey.present?

          true
        end
      end
    end
  end
end
