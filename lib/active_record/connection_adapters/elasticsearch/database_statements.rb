# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      module DatabaseStatements

        # detects if a query is a write query.
        # since we don't provide a simple string / hash we can now access the query-object and ask for it :)
        # @see ActiveRecord::ConnectionAdapters::DatabaseStatements#write_query?
        # @param [ElasticsearchRecord::Query] query
        # @return [Boolean]
        def write_query?(query)
          query.write?
        end

        # gets called for all queries
        # @param [ElasticsearchRecord::Query] query
        # @param [String (frozen)] name
        # @param [Array] binds
        # @param [Boolean] prepare - used by the default AbstractAdapter - but not supported and therefore never used!
        # @param [Boolean] async
        # @return [ElasticsearchRecord::Result]
        def exec_query(query, name = "QUERY", binds = [], prepare: false, async: false)
          # validate the query
          raise ActiveRecord::StatementInvalid, 'Unable to execute invalid query' unless query.valid?

          # checks for write query - raises an exception if connection is locked to readonly ...
          check_if_write_query(query)

          build_result(
            api(*query.gate, query.arguments, name, async: async),
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
            index: query.index,
            type:  ElasticsearchRecord::Query::TYPE_COUNT,
            body:  query.body)

          exec_query(query, name, async: async).response['count']
        end

        # # This is used in the StatementCache object. It returns an object that
        # # can be used to query the database repeatedly.
        # # @see ActiveRecord::ConnectionAdapters::DatabaseStatements#cacheable_query
        # def cacheable_query(klass, arel) # :nodoc:
        #   # the provided klass is a ActiveRecord::StatementCache and only supports SQL _(String)_ queries.
        #   # We force overwrite this class with our own
        #
        #
        #   ActiveRecord::StatementCache.partial_query_collector
        #
        #   raise "STOP HERE!!!!!!"
        #   if prepared_statements
        #     sql, binds = visitor.compile(arel.ast, collector)
        #     query = klass.query(sql)
        #   else
        #     collector = klass.partial_query_collector
        #     parts, binds = visitor.compile(arel.ast, collector)
        #     query = klass.partial_query(parts)
        #   end
        #   [query, binds]
        # end

        # calls the +elasticsearch-api+ endpoints by provided namespace and action.
        # if a block was provided it'll yield the response.body and returns the blocks result.
        # otherwise it will return the response itself...
        # @param [Symbol] namespace - the API namespace (e.g. indices, nodes, sql, ...)
        # @param [Symbol] action - the API action to call in tha namespace
        # @param [Hash] arguments - action arguments
        # @param [String (frozen)] name - the logging name
        # @param [Boolean] async - send async (default: false) - currently not supported
        # @return [Elasticsearch::API::Response, Object]
        def api(namespace, action, arguments = {}, name = 'API', async: false)
          raise ::StandardError, 'ASYNC api calls are not supported' if async

          # resolve the API target
          target = namespace == :core ? @connection : @connection.__send__(namespace)

          log("#{namespace}.#{action}", arguments, name, async: async) do
            response = ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
              target.__send__(action, arguments)
            end

            if response.is_a?(::Elasticsearch::API::Response)
              # reverse information for the LogSubscriber - shows the 'query-time' in the logs
              # this works, since we use a referenced hash ...
              arguments[:_qt] = response['took']

              # raise timeouts
              raise(ActiveRecord::StatementTimeout, "Elasticsearch api request failed due a timeout") if response['timed_out']
            end

            response
          end
        end
      end
    end
  end
end
