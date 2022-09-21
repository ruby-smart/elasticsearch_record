# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class Column < ConnectionAdapters::Column # :nodoc:

        attr_reader :virtual, :fields

        def initialize(name, default, sql_type_metadata = nil, null = true, default_function = nil, **kwargs)
          @virtual = kwargs.delete(:virtual)
          @fields  = kwargs.delete(:fields)
          super(name, default, sql_type_metadata, null, default_function, **kwargs)
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
      end
    end
  end
end
