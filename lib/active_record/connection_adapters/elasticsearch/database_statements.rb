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

        # executes a plain SQL query
        # toDo: this is not final ... build_result is missing ... - also better use a query-builder ...
        def exec_sql(sql, name = "SQL")
          api(:sql, :query, { body: { query: sql } }, name)
        end

        # gets called for all queries
        # @param [ElasticsearchRecord::Query] query
        # @param [String (frozen)] name
        # @param [Array] binds
        # @param [Boolean] prepare
        # @param [Boolean] async
        # @return [ElasticsearchRecord::Result]
        def exec_query(query, name = "QUERY", binds = [], prepare: false, async: false)
          # validate the query
          raise ActiveRecord::StatementInvalid, 'Unable to execute invalid query' unless query.valid?

          # checks for write query - raises an exception if connection is locked to readonly ...
          check_if_write_query(query)

          build_result(
            api(*query.api_gate, query.arguments, name, binds, async: async),
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
        def select_multiple(arels, name = "Multi", binds = [], preparable: false, async: false)
          # transform arels to query objects
          queries = arels.map { |arel| to_sql(arel_from_relation(arel)) }

          # build new msearch query
          query = ElasticsearchRecord::Query.new(
            index: queries.first&.index,
            type:  ElasticsearchRecord::Query::TYPE_MSEARCH,
            body:  queries.map { |q| { search: q.body } })

          exec_query(query, name, binds, prepare: preparable, async: async)
        end

        private

        # calls the +elasticsearch-api+ endpoints by provided namespace and action.
        # if a block was provided it'll yield the response.body and returns the blocks result.
        # otherwise it will return the response itself...
        # @param [Symbol] namespace - the API namespace (e.g. indices, nodes, sql, ...)
        # @param [Symbol] action - the API action to call in tha namespace
        # @param [Hash] arguments - action arguments
        # @param [String (frozen)] name - the logging name
        # @param [Boolean] async - send async (default: false) - not implemented yet
        # @return [Elasticsearch::API::Response, Object]
        def api(namespace, action, arguments = {}, name = 'API', binds = [], async: false)
          response = log("#{namespace}.#{action}", arguments, name, binds, async: async) do
            result = ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
              if namespace == :core
                @connection.__send__(action, arguments)
              else
                @connection.__send__(namespace).__send__(action, arguments)
              end
            end

            # reverse information for the LogSubscriber - shows the 'query-time' in the logs
            arguments[:_qt] = result['took'] if result.is_a?(::Elasticsearch::API::Response)

            result
          end

          # raise timeouts
          if response['timed_out']
            raise(ActiveRecord::StatementTimeout, "Elasticsearch api request failed due a timeout")
          end

          # return response
          response
        end
      end
    end
  end
end
