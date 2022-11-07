# frozen_string_literal: true

module ElasticsearchRecord
  module Tasks
    class ElasticsearchDatabaseTasks
      delegate :connection, :establish_connection, to: ActiveRecord::Base

      def initialize(db_config)
        @db_config = db_config
      end

      def create
        #establish_connection(db_config)
        $stdout.puts "\n>>> 'create' elasticsearch is not supported - the following message is insignificant!"
      end

      def drop
        #establish_connection(db_config)
        $stdout.puts "\n>>> 'drop' elasticsearch is not supported - the following message is insignificant!"
      end

      def purge
        create
        drop
      end

      private

      attr_reader :db_config
    end
  end
end