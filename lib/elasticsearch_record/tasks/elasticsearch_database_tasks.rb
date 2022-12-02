# frozen_string_literal: true

module ElasticsearchRecord
  module Tasks
    class ElasticsearchDatabaseTasks
      delegate :connection, :establish_connection, to: ElasticsearchRecord::Base

      def initialize(db_config)
        @db_config = db_config
      end

      def create
        # 'create' database / cluster is not supported
        nil
      end

      def drop
        # 'drop' database / cluster is not supported
        nil
      end

      def purge
        create
        drop
      end

      def structure_dump(*)
        $stdout.puts "\n>>> 'structure_dump' elasticsearch is not supported and will be ignored!"
        nil
      end

      def structure_load(*)
        $stdout.puts "\n>>> 'structure_load' elasticsearch is not supported and will be ignored!"
        nil
      end

      private

      attr_reader :db_config
    end
  end
end