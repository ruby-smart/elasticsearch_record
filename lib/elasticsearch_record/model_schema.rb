module ElasticsearchRecord
  module ModelSchema
    extend ActiveSupport::Concern

    included do
      class_attribute :index_base_name, instance_writer: false, default: nil
    end

    module ClassMethods
      # Guesses the table name, but does not decorate it with prefix and suffix information.
      def undecorated_table_name(model_name)
        # check the 'index_base_name' first, so +table_name_prefix+ & +table_name_suffix+ can still be used
        index_base_name || super(model_name)
      end

      # returns an array with columns names, that are not virtual (and not a base structure).
      # so this is a array of real document (+_source+) attributes of the index.
      # @return [Array<String>]
      def source_column_names
        @source_column_names ||= columns.reject(&:virtual).map(&:name) - ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.base_structure_keys
      end

      # returns an array with columns names, that are searchable (also includes nested )
      def searchable_column_names
        @searchable_column_names ||= columns.reject(&:virtual).reduce([]) { |m, column|
          m << column.name
          m += column.fields if column.fields?
          m
        }
      end

      # clears schema-related instance variables.
      # @see ActiveRecord::ModelSchema::ClassMethods#reload_schema_from_cache
      def reload_schema_from_cache
        # we also need to clear our custom-defined variables
        @source_column_names     = nil
        @searchable_column_names = nil

        super
      end
    end
  end
end