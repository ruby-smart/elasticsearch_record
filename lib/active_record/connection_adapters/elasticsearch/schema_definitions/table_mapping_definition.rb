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
        #
        # PLEASE NOTE: this list is only enforced for a +strict: true+ definition - every other
        # definition forwards unknown parameters to the cluster untouched. It therefore has to stay
        # in sync with the field types +ColumnMethods+ exposes, or +strict+ becomes unusable for
        # them (which is exactly what happened for +dense_vector+, +semantic_text+ & friends).
        ATTRIBUTES = [:analyzer, :coerce, :copy_to, :doc_values, :dynamic, :eager_global_ordinals, :enabled,
                      :fielddata, :fields, :format, :ignore_above, :ignore_malformed, :index_options, :index_phrases,
                      :index_prefixes, :index, :meta, :normalizer, :norms, :null_value, :position_increment_gap,
                      :properties, :search_analyzer, :similarity, :subobjects, :store, :term_vector,

                      # -- vectors (dense_vector, sparse_vector) --------------------------------------
                      :dims, :element_type,

                      # -- semantic_text (>= 8.15) -----------------------------------------------------
                      :inference_id, :search_inference_id, :chunking_settings,

                      # -- aggregate_metric_double -----------------------------------------------------
                      :metrics, :default_metric,

                      # -- constant_keyword ------------------------------------------------------------
                      :value,

                      # -- time series (TSDS) ----------------------------------------------------------
                      :time_series_dimension, :time_series_metric,

                      # -- remaining type specific parameters ------------------------------------------
                      :depth_limit, :scaling_factor, :max_input_length, :positive_score_impact,
                      :relations, :path, :orientation, :ignore_z_value, :boost, :locale,
                      :null_value_as_boolean, :preserve_position_increments, :split_queries_on_whitespace,
                      :max_shingle_size, :script, :on_script_error, :dynamic_templates].freeze

        # define virtual attributes, that must be assigned due a special logic
        ASSIGNABLE_ATTRIBUTES = [:comment, :primary_key, :auto_increment, :meta].freeze

        build_attribute_methods! *ATTRIBUTES

        # attributes
        attr_accessor :name
        attr_accessor :type
        attr_accessor :attributes

        # validations
        validates_presence_of :name
        validates_presence_of :type
        validates_inclusion_of :__attributes_keys, in: ATTRIBUTES, allow_blank: true
        validate :_validate_meta

        # sets the default value (alias for null_value)
        alias_method :default=, :null_value=
        alias_method :default, :null_value

        ####################
        # INSTANCE METHODS #
        ####################

        def initialize(name, type, attributes)
          @name = name.to_sym

          attributes = attributes.symbolize_keys
          # directly set attributes, that cannot be assigned
          @attributes = attributes.except(*ASSIGNABLE_ATTRIBUTES)
          # assign special attributes
          __assign(attributes.slice(*ASSIGNABLE_ATTRIBUTES))

          @type = _resolve_type(type)
        end

        # returns the +comment+ from 'meta' attribute
        # @return [String, nil]
        def comment
          __get_nested(:meta, :comment)
        end

        # sets the +comment+ as 'meta' attribute
        # @param [String] value
        def comment=(value)
          # important: meta-values can only be strings!
          __set_nested(:meta, :comment, value.to_s)
        end

        # returns true if the +primary_key+ 'attribute' was provided
        # @return [Boolean]
        def primary_key
          !!_lazy_attributes[:primary_key]
        end

        alias_method :primary_key?, :primary_key

        # sets the +primary_key+ as 'lazy_attribute'
        # @param [Boolean] value
        def primary_key=(value)
          _lazy_attributes[:primary_key] = value
        end

        # returns the +auto_increment+ value, if provided
        # @return [Integer]
        def auto_increment
          return nil unless _lazy_attributes[:auto_increment]
          return 0 if _lazy_attributes[:auto_increment] == true
          _lazy_attributes[:auto_increment].to_i
        end

        # returns true if the +auto_increment+ 'attribute' was provided
        # @return [Boolean]
        def auto_increment?
          !!auto_increment
        end

        # sets the +auto_increment+ as 'lazy_attribute'
        # @param [Boolean, Integer] value
        def auto_increment=(value)
          _lazy_attributes[:auto_increment] = value
        end

        # returns the meta hash
        # @return [Hash]
        def meta
          __get_attribute(:meta) || {}
        end

        def meta=(value)
          if value.nil?
            __remove_attribute(:meta)
          else
            __set_attribute(:meta, value.compact)
          end
        end

        private

        # non persistent attributes
        def _lazy_attributes
          @_lazy_attributes ||= {}
        end

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
          failed_key = meta.keys.detect { |key| !meta[key].is_a?(String) }
          return invalid!("'meta' has a key '#{failed_key}' with a none string value", :attributes) if failed_key.present?

          true
        end
      end
    end
  end
end
