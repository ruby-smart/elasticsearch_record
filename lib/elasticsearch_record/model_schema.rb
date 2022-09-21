module ElasticsearchRecord
  module ModelSchema
    extend ActiveSupport::Concern

    included do
      class_attribute :index_name, instance_writer: false, default: nil
      class_attribute :index_delimiter, instance_writer: false, default: "_"
    end

    module ClassMethods
      # Guesses the table name, but does not decorate it with prefix and suffix information.
      def undecorated_table_name(model_name)
        klass = model_name.instance_variable_get(:@klass)

        klass.index_name || begin
                              table_name = model_name.to_s.demodulize.underscore.split('_').join(klass.index_delimiter)
                              pluralize_table_names ? table_name.pluralize : table_name
                            end
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