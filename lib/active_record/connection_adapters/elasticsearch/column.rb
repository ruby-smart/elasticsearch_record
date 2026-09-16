# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class Column < ConnectionAdapters::Column # :nodoc:

        attr_reader :virtual, :fields, :properties, :meta, :enabled

        def initialize(name, cast_type, default, sql_type_metadata = nil, virtual: false, fields: nil, properties: nil, meta: nil, enabled: nil, **kwargs)
          @virtual    = virtual
          @fields     = fields.presence || []
          @properties = properties.presence || []
          @meta       = meta.presence || {}
          @enabled    = enabled.nil? ? true : enabled

          super(name, cast_type, default, sql_type_metadata, true, nil, **kwargs)
        end

        # returns comment from meta
        def comment
          meta? && meta['comment']
        end

        def init_with(coder)
          @virtual    = coder['virtual']
          @fields     = coder['fields']
          @properties = coder['properties']
          @meta       = coder['meta']
          @enabled    = coder['enabled']
          super
        end

        def encode_with(coder)
          coder['virtual']    = @virtual
          coder['fields']     = @fields
          coder['properties'] = @properties
          coder['meta']       = @meta
          coder['enabled']    = @enabled
          super
        end

        # ActiveRecord deduplicates columns process-wide through +Deduplicable+, which
        # keys its registry by +#hash+ & +#eql?+ - so columns that only differ in the
        # elasticsearch-specific attributes must NOT compare equal.
        # Without this a +keyword+ column with a +analyzed+ sub-field would share the
        # object of a same-named +keyword+ column without any fields - whichever index
        # loaded its schema first wins & the other one silently gains or loses its
        # +fields+ (breaking e.g. +where('code.analyzed' => ...)+).
        def ==(other)
          other.is_a?(Column) &&
            super &&
            virtual == other.virtual &&
            fields == other.fields &&
            properties == other.properties &&
            meta == other.meta &&
            enabled == other.enabled
        end

        alias :eql? :==

        def hash
          Column.hash ^
            super.hash ^
            virtual.hash ^
            fields.hash ^
            properties.hash ^
            meta.hash ^
            enabled.hash
        end

        # returns true if this column is enabled (= searchable by queries)
        # @return [Boolean]
        def enabled?
          !!enabled
        end

        # returns true if this column is virtual.
        # Virtual columns cannot be saved.
        # @return [Boolean]
        def virtual?
          !!virtual
        end

        # returns true if this column has meta information
        # To receive the nested meta-data just call +#meta+ on this object.
        # @return [Boolean]
        def meta?
          meta.present?
        end

        # returns true if this column has nested fields
        # To receive the nested names just call +#fields+ on this object.
        # @return [Boolean]
        def fields?
          fields.present?
        end

        # returns true if this column has nested properties
        # To receive the nested names just call +#properties+ on this object.
        # @return [Boolean]
        def properties?
          properties.present?
        end

        # returns a array of field names
        # @return [Array]
        def field_names
          return [] unless fields?

          fields.map { |field| field['name'] }
        end

        # returns a array of property names
        # @return [Array]
        def property_names
          return [] unless properties?

          properties.map { |property| property['name'] }
        end
      end
    end
  end
end
