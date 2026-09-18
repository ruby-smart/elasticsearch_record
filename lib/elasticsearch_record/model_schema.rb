module ElasticsearchRecord
  module ModelSchema
    extend ActiveSupport::Concern

    included do
      # Rails resolves a pluralized underscore table_name from the class name - which will not work for some models.
      # To support a general +table_name_prefix+ & +table_name_suffix+ a custom 'index_base_name' can be provided.
      # @attribute! String|Symbol
      class_attribute :index_base_name, instance_writer: false, default: nil
    end

    module ClassMethods
      # overwrite this method to provide an optional +table_name_prefix+ from the connection config.
      #
      # IMPORTANT: this is a pure CONFIG lookup - the value is resolved from the pool's +db_config+
      # and NOT through the adapter, so it does not check a connection out of the pool. The
      # +table_name+ of a model is resolved on class definition and on every schema access, which
      # would otherwise lease a connection long before the model ever runs a query.
      # see @ ActiveRecord::ConnectionAdapters::ElasticsearchAdapter#table_name_prefix
      # @return [String]
      def table_name_prefix
        super.presence || connection_db_config.configuration_hash.fetch(:table_name_prefix, '')
      end

      # overwrite this method to provide an optional +table_name_suffix+ from the connection config.
      # see @ #table_name_prefix - resolved from the config, without a connection
      # @return [String]
      def table_name_suffix
        super.presence || connection_db_config.configuration_hash.fetch(:table_name_suffix, '')
      end

      # Guesses the table name, but does not decorate it with prefix and suffix information.
      def undecorated_table_name(model_name)
        # check the 'index_base_name' first, so +table_name_prefix+ & +table_name_suffix+ can still be used
        index_base_name || super(model_name)
      end

      # returns the configured +max_result_window+ (default: 10000)
      # @return [Integer]
      def max_result_window
        @max_result_window ||= with_connection { |c| c.max_result_window(table_name) }
      end

      # returns true, if the table should behave as +auto_increment+ by creating new records.
      # resolves the auto_increment status from the tables +_meta+.
      #
      # IMPORTANT: a +false+ status must be cached as well - a +||=+ never memoizes it, which
      # resolved the mapping of a regular (non auto_increment) index on EVERY single insert.
      # The status is cleared through +#reload_schema_from_cache+ (e.g. +reset_column_information+).
      # @return [Boolean]
      def auto_increment?
        return @auto_increment unless @auto_increment.nil?

        @auto_increment = with_connection { |c| !!c.table_metas(table_name).dig('auto_increment') }
      end

      # returns an array with columns names, that are not virtual (and not a base structure).
      # so this is a array of real document (+_source+) attributes of the index.
      # @return [Array<String>]
      def source_column_names
        @source_column_names ||= columns.reject(&:virtual?).map(&:name) - ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.metadata_keys
      end

      # returns an array with columns names, that are searchable (also includes nested fields & properties )
      # @return [Array<String>]
      def searchable_column_names
        @searchable_column_names ||= columns.select(&:enabled?).reduce([]) { |m, column|
          m + [column.name] + column.field_names + column.property_names
        }.uniq
      end

      # clears schema-related instance variables.
      # @see ActiveRecord::ModelSchema::ClassMethods#reload_schema_from_cache
      def reload_schema_from_cache(recursive = true)
        # we also need to clear our custom-defined variables
        @source_column_names     = nil
        @searchable_column_names = nil
        @max_result_window       = nil
        @auto_increment          = nil

        super
      end
    end
  end
end