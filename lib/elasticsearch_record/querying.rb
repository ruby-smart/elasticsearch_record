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
      # @param [Boolean] allow_retry
      # @param [Proc] block
      def find_by_sql(sql, binds = [], preparable: nil, allow_retry: false, &block)
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

        result = with_connection do |c|
          _query_by_sql(c, query, binds, preparable: preparable, allow_retry: allow_retry)
        end

        _load_from_sql(result, &block)
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

        result = with_connection do |c|
          _query_by_sql(c, query)
        end

        _load_from_sql(result, &block)
      end

      # ES|QL query API
      # Returns search results for an ES|QL (Elasticsearch query language) query.
      #
      # @param [String] esql
      # @param [Proc] block
      def find_by_esql(esql, &block)
        # build new query
        query = ElasticsearchRecord::Query.new(
          type: ElasticsearchRecord::Query::TYPE_ESQL,
          body: { query: esql },
          # IMPORTANT: Always provide all columns
          columns: source_column_names)

        result = with_connection do |c|
          _query_by_sql(c, query)
        end

        _load_from_sql(result, &block)
      end

      # executes a +esql+ by provided *ES|SL* query
      # Does NOT instantiate records.
      # @param [String] esql
      def esql(esql)
        # build new query
        query = ElasticsearchRecord::Query.new(
          type: ElasticsearchRecord::Query::TYPE_ESQL,
          body: { query: esql },
          # IMPORTANT: Always provide all columns
          columns: source_column_names)

        connection.exec_query(query, "#{name} ES|QL")
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

      # executes a search by provided +RAW+ query - supports +Elasticsearch::DSL+ gem if loaded.
      #
      # Without a block the trailing options-hash is used as query arguments.
      # With a block the +Elasticsearch::DSL+ gem builds the query - if the gem is not
      # available (or the block fails), the block is SILENTLY ignored and the
      # options-hash is used instead.
      def search(*args, &block)
        query = if block_given?
                  begin
                    # require the Elasticsearch::DSL gem, if loaded
                    require 'elasticsearch/dsl'
                    # PLEASE NOTE: +Search#to_hash+ returns the request BODY - it must be nested
                    # into the query arguments, otherwise it is sent as (invalid) URL parameters.
                    { body: ::Elasticsearch::DSL::Search::Search.new(*args, &block).to_hash }
                  rescue LoadError
                    args.extract_options!
                  rescue
                    args.extract_options!
                  end
                else
                  args.extract_options!
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
