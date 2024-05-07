# frozen_string_literal: true

require "active_record/schema_migration"

module ElasticsearchRecord
  class SchemaMigration < ::ActiveRecord::SchemaMigration

    def table_name
      "#{ElasticsearchRecord::Base.table_name_prefix}#{ElasticsearchRecord::Base.schema_migrations_table_name}#{ElasticsearchRecord::Base.table_name_suffix}"
    end

    # overwrite method to fix the default limit (= 10) to support returning more than 10 migrations
    def versions
      sm = Arel::SelectManager.new(arel_table)
      sm.project(arel_table[primary_key])
      sm.order(arel_table[primary_key].asc)
      sm.take(connection.max_result_window(table_name))

      connection.select_values(sm, "#{self.class} Load")
    end
  end
end
