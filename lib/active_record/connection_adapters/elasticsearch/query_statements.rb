# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      module QueryStatements
        # detects if a query is a write query.
        # since we don't provide a simple string / hash we can now access the query-object and ask for it :)
        # @see ActiveRecord::ConnectionAdapters::DatabaseStatements#write_query?
        # @param [ElasticsearchRecord::Query] query
        # @return [Boolean]
        def write_query?(query)
          query.write?
        end

        # Executes the query object in the context of this connection and returns
        # the raw result from the connection adapter.
        # Note: depending on your database connector, the result returned by this
        # method may be manually memory managed. Consider using the exec_query
        # wrapper instead.
        def execute(query, name = nil, async: false)
          # validate the query
          raise ActiveRecord::StatementInvalid, 'Unable to execute! Provided query is not a "ElasticsearchRecord::Query".' unless query.is_a?(ElasticsearchRecord::Query)
          raise ActiveRecord::StatementInvalid, 'Unable to execute! Provided query is invalid.' unless query.valid?

          # checks for write query - raises an exception if connection is locked to readonly ...
          check_if_write_query(query)

          api(*query.gate, query.query_arguments, name, async: async)
        end

        # gets called for all queries - a +ElasticsearchRecord::Query+ must be provided.
        # @param [ElasticsearchRecord::Query] query
        # @param [String (frozen)] name
        # @param [Array] binds - not supported on the top-level and therefore ignored!
        # @param [Boolean] prepare - used by the default AbstractAdapter - but not supported and therefore never ignored!
        # @param [Boolean] async
        # @return [ElasticsearchRecord::Result]
        def exec_query(query, name = "QUERY", binds = [], prepare: false, async: false)
          build_result(
            execute(query, name, async: async),
            columns: query.columns
          )
        end

        # Executes insert +query+ statement in the context of this connection using
        # +binds+ as the bind substitutes. +name+ is logged along with
        # the executed +query+ arguments.
        def exec_insert(query, name = nil, binds = [], _pk = nil, _sequence_name = nil)
          exec_query(query, name, binds)
        end

        # Executes delete +query+ statement in the context of this connection using
        # +binds+ as the bind substitutes. +name+ is logged along with
        # the executed +query+ arguments.
        # expects a integer as return.
        # @return [Integer]
        def exec_delete(query, name = nil, binds = [])
          exec_query(query, name, binds).total
        end

        # Executes update +query+ statement in the context of this connection using
        # +binds+ as the bind substitutes. +name+ is logged along with
        # the executed +query+ arguments.
        # expects a integer as return.
        # @return [Integer]
        def exec_update(query, name = nil, binds = [])
          exec_query(query, name, binds).total
        end

        # executes a msearch for provided arels
        # @return [ElasticsearchRecord::Result]
        def select_multiple(arels, name = "Multi", async: false)
          # transform arels to query objects
          queries = arels.map { |arel| to_sql(arel_from_relation(arel)) }

          # build new msearch query
          query = ElasticsearchRecord::Query.new(
            index: queries.first&.index,
            type:  ElasticsearchRecord::Query::TYPE_MSEARCH,
            body:  queries.map { |q| { search: q.body } })

          exec_query(query, name, async: async)
        end

        # executes a count query for provided arel
        # @return [Integer]
        def select_count(arel, name = "Count", async: false)
          query = to_sql(arel_from_relation(arel))

          # build new count query from existing query
          query = ElasticsearchRecord::Query.new(
            index:     query.index,
            type:      ElasticsearchRecord::Query::TYPE_COUNT,
            body:      query.body,
            arguments: query.arguments)

          exec_query(query, name, async: async).response['count']
        end
      end
    end
  end
end
