# frozen_string_literal: true

require 'active_record/schema_migration'

module ElasticsearchRecord
  # temporary workaround
  # toDo: fixme - or REMOVE
  class SchemaMigration < ActiveRecord::SchemaMigration # :nodoc:
    class << self
      def create_table
        $stdout.puts "\n>>> 'create_table' elasticsearch is not supported - the following message is insignificant!"
      end

      def drop_table
        $stdout.puts "\n>>> 'drop_table' elasticsearch is not supported - the following message is insignificant!"
      end

      def normalized_versions
        []
      end

      def all_versions
        []
      end

      def table_exists?
        true
      end
    end
  end
end
