# frozen_string_literal: true

module ElasticsearchRecord
  module Querying
    extend ActiveSupport::Concern

    module ClassMethods
      # define additional METHODS to be delegated to the Relation
      # @see ::ActiveRecord::Querying::QUERYING_METHODS
      ES_QUERYING_METHODS = [
        :query,
        :filter,
        :must,
        :must_not,
        :should,
        :aggregate,
        :msearch
      ].freeze # :nodoc:
      delegate(*ES_QUERYING_METHODS, to: :all)

      # finds a single record by provided id.
      # This method is overwritten to support the primary key column (+_id+).
      # @param [Object] id
      def find_by_id(id)
        has_attribute?('id') ? super(id) : public_send(:find_by__id, id)
      end

      # finds records by sql, query-arguments or query-object.
      #
      # PLEASE NOTE: This method is used by different other methods:
      # - ActiveRecord::Relation#exec_queries
      # - ActiveRecord::StatementCache#execute
      # - <directly on demand>
      #
      # We cannot rewrite all call-sources since this will mess up the whole logic end will end in other problems.
      # So we check here what kind of query is provided and decide what to do.
      #
      # PLEASE NOTE: since ths is also used by +ActiveRecord::StatementCache#execute+ we cannot remove
      # the unused params +preparable+.
      # see @ ActiveRecord::Querying#find_by_sql
      #
      # @param [String, Hash, ElasticsearchRecord::Query] sql
      # @param [Array] binds
      # @param [nil] preparable
      # @param [Proc] block
      def find_by_sql(sql, binds = [], preparable: nil, &block)
        query = case sql
                when String # really find by SQL
                  ElasticsearchRecord::Query.new(
                    type: ElasticsearchRecord::Query::TYPE_SQL,
                    body: { query: query_or_sql },
                    # IMPORTANT: Always provide all columns
                    columns: source_column_names)
                when Hash
                  ElasticsearchRecord::Query.new(
                    type:      ElasticsearchRecord::Query::TYPE_SEARCH,
                    arguments: sql,
                    # IMPORTANT: Always provide all columns
                    columns: source_column_names)
                else
                  sql
                end

        _load_from_sql(_query_by_sql(query, binds), &block)
      end

      # finds records by query arguments
      def find_by_query(arguments, &block)
        # build new query
        query = ElasticsearchRecord::Query.new(
          index:     table_name,
          type:      ElasticsearchRecord::Query::TYPE_SEARCH,
          arguments: arguments,
          # IMPORTANT: Always provide all columns to prevent unknown attributes that should be nil ...
          columns: source_column_names)

        _load_from_sql(_query_by_sql(query), &block)
      end

      # executes a msearch by provided +RAW+ queries
      def msearch(queries, async: false)
        # build new msearch query
        query = ElasticsearchRecord::Query.new(
          index: table_name,
          type:  ElasticsearchRecord::Query::TYPE_MSEARCH,
          body:  queries.map { |q| { search: q } },
          # IMPORTANT: Always provide all columns
          columns: source_column_names)

        connection.exec_query(query, "#{name} Msearch", async: async)
      end

      # executes a search by provided +RAW+ query - supports +Elasticsearch::DSL+ gem if loaded
      def search(*args, &block)
        begin
          # require the Elasticsearch::DSL gem, if loaded
          require 'elasticsearch/dsl'
          query = ::Elasticsearch::DSL::Search::Search.new(*args, &block).to_hash
        rescue LoadError
          query = args.extract_options!
        rescue
          query = args.extract_options!
        end

        find_by_query(query)
      end

      # execute query by msearch
      def _query_by_msearch(queries, async: false)
        connection.select_multiple(queries, "#{name} Msearch", async: async)
      end
    end
  end
end
