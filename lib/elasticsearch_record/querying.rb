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
                    body: { query: sql },
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

      # ES|QL query API
      # Returns search results for an ES|QL (Elasticsearch query language) query.
      #
      # @param [String] esql
      # @param [Boolean, nil] allow_partial_results - see @ #esql
      # @param [Proc] block
      def find_by_esql(esql, allow_partial_results: nil, &block)
        _load_from_sql(_query_by_sql(_esql_query(esql, allow_partial_results)), &block)
      end

      # executes a +esql+ by provided *ES|SL* query
      # Does NOT instantiate records.
      #
      # PLEASE NOTE: since Elasticsearch 8.19 a ES|QL query answers with PARTIAL results instead of
      # failing, whenever a shard is unavailable or the query times out. Provide
      # +allow_partial_results: false+ to restore the former "fail loudly" behaviour for a single
      # query - or set +ElasticsearchRecord.error_on_partial_results+ to raise on the client side.
      #
      # @param [String] esql
      # @param [Boolean, nil] allow_partial_results
      def esql(esql, allow_partial_results: nil)
        connection.exec_query(_esql_query(esql, allow_partial_results), "#{name} ES|QL")
      end


      # executes a +msearch+ by provided *RAW* queries.
      # Does NOT instantiate records.
      # @param [Array<String>] queries
      def msearch(queries)
        # build new msearch query
        query = ElasticsearchRecord::Query.new(
          index: table_name,
          type:  ElasticsearchRecord::Query::TYPE_MSEARCH,
          body:  queries.map { |q| { search: q } },
          # IMPORTANT: Always provide all columns
          columns: source_column_names)

        connection.exec_query(query, "#{name} Msearch")
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

      private

      # builds the +ES|QL+ query and validates that the cluster can actually run it.
      # @param [String] esql
      # @param [Boolean, nil] allow_partial_results
      # @return [ElasticsearchRecord::Query]
      def _esql_query(esql, allow_partial_results = nil)
        # the 'esql' API namespace simply does not exist before 8.11 - without this guard the call
        # fails deep inside the client with a hardly readable NoMethodError
        if connection.cluster_info[:version] < ElasticsearchRecord::Query::ESQL_MIN_VERSION
          raise ::ActiveRecord::StatementInvalid,
                "ES|QL requires Elasticsearch >= #{ElasticsearchRecord::Query::ESQL_MIN_VERSION} " \
                "(this cluster runs #{connection.cluster_info[:version]})"
        end

        arguments = allow_partial_results.nil? ? {} : { allow_partial_results: allow_partial_results }

        ElasticsearchRecord::Query.new(
          type:      ElasticsearchRecord::Query::TYPE_ESQL,
          body:      { query: esql },
          arguments: arguments,
          # IMPORTANT: Always provide all columns
          columns:   source_column_names)
      end
    end
  end
end
