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

      # Since rails 8.1 the protected-environment check of 'db:drop', 'db:purge', 'db:schema:load'
      # & co. is asked of the tasks class of every database config
      # (+ActiveRecord::Tasks::DatabaseTasks.check_protected_environments!+) - without this method
      # each of these tasks aborts with a NoMethodError.
      # The cluster never stores an environment (+ElasticsearchRecord::InternalMetadata#enabled?+ is
      # false), so there is nothing to protect or to mismatch - the outcome the central check of
      # rails <= 8.0 had for an elasticsearch config as well.
      def check_current_protected_environment!(*)
        nil
      end

      private

      attr_reader :db_config
    end
  end
end