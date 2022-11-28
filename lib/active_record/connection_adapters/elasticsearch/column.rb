# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class Column < ConnectionAdapters::Column # :nodoc:

        attr_reader :virtual, :fields, :properties

        def initialize(name, default, sql_type_metadata = nil, **kwargs)
          @virtual    = kwargs.delete(:virtual)
          @fields     = kwargs.delete(:fields)
          @properties = kwargs.delete(:properties)
          super(name, default, sql_type_metadata, true, nil, **kwargs)
        end

        # returns true if this column is virtual.
        # Virtual columns cannot be saved.
        # @return [Boolean]
        def virtual?
          !!virtual
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
