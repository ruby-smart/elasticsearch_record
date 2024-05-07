# frozen_string_literal: true

require "active_record/schema_migration"

module ElasticsearchRecord
  class SchemaMigration < ElasticsearchRecord::Base # :nodoc:
    class << self
      def primary_key
        "version"
      end

      def table_name
        "#{table_name_prefix}#{schema_migrations_table_name}#{table_name_suffix}"
      end

      def create_table
        unless connection.table_exists?(table_name)
          connection.create_table(table_name, id: false) do |t|
            t.string :version, **connection.internal_string_options_for_primary_key
          end
        end
      end

      def drop_table
        connection.drop_table table_name, if_exists: true
      end

      def normalize_migration_number(number)
        "%.3d" % number.to_i
      end

      def normalized_versions
        all_versions.map { |v| normalize_migration_number v }
      end

      def all_versions
        # Elasticsearch's default value for queries without a size is forced to 10.
        # Using *__max__* to set it to the +max_result_window+ value.
        order(:version).limit('__max__').pluck(:version)
      end

      def table_exists?
        connection.data_source_exists?(table_name)
      end
    end

    def version
      super.to_i
    end
  end
end
