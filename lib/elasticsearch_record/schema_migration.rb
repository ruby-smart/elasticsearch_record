# frozen_string_literal: true

require "active_record/schema_migration"

module ElasticsearchRecord
  class SchemaMigration < ::ActiveRecord::SchemaMigration

    def table_name
      "#{ElasticsearchRecord::Base.table_name_prefix}#{ElasticsearchRecord::Base.schema_migrations_table_name}#{ElasticsearchRecord::Base.table_name_suffix}"
    end
  end
end
