# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      # extend adapter with query-related statements
      #
      # *ORIGINAL* methods untouched:
      # - to_sql
      # - to_sql_and_binds
      # - insert
      # - create
      # - update
      # - delete
      # - arel_from_relation
      #
      # *SUPPORTED* but not used:
      # - select
      # - select_all
      # - select_one
      # - select_value
      # - select_values
      #
      # *UNSUPPORTED* methods that will be +ignored+:
      # - build_fixture_sql
      # - build_fixture_statements
      # - build_truncate_statement
      # - build_truncate_statements
      #
      # *UNSUPPORTED* methods that will +fail+:
      # - insert_fixture
      # - insert_fixtures_set
      # - execute_batch
      # - select_prepared
      # - combine_multi_statements
      #
      module DatabaseStatements
        extend ActiveSupport::Concern

        included do
          define_unsupported_method :insert_fixture, :insert_fixtures_set, :execute_batch, :select_prepared,
                                    :combine_multi_statements

          # detects if a query is a write query.
          # since we don't provide a simple string / hash we can now access the query-object and ask for it :)
          # @see ActiveRecord::ConnectionAdapters::DatabaseStatements#write_query?
          # @param [ElasticsearchRecord::Query] query
          # @return [Boolean]
          def write_query?(query)
            query.write?
          end

          # Executes insert +query+ statement in the context of this connection using
          # +binds+ as the bind substitutes. +name+ is logged along with
          # the executed +query+ arguments.
          # @return [ElasticsearchRecord::Result]
          def exec_insert(query, name = nil, binds = [], _pk = nil, _sequence_name = nil, returning: nil)
            result = internal_exec_query(query, name, binds)

            # fetch additional Elasticsearch response result
            # raise ::ElasticsearchRecord::ResponseResultError.new('created', result.result) unless result.result == 'created'

            # return the result object
            result
          end

          # Executes update +query+ statement in the context of this connection using
          # +binds+ as the bind substitutes. +name+ is logged along with
          # the executed +query+ arguments.
          # expects a integer as return.
          # @return [Integer]
          def exec_update(query, name = nil, binds = [])
            result = internal_exec_query(query, name, binds)

            # fetch additional Elasticsearch response result
            # raise ::ElasticsearchRecord::ResponseResultError.new('updated', result.result) unless result.result == 'updated'

            result.total
          end

          # Executes delete +query+ statement in the context of this connection using
          # +binds+ as the bind substitutes. +name+ is logged along with
          # the executed +query+ arguments.
          # expects a integer as return.
          # @return [Integer]
          def exec_delete(query, name = nil, binds = [])
            result = internal_exec_query(query, name, binds)

            # fetch additional Elasticsearch response result
            # raise ::ElasticsearchRecord::ResponseResultError.new('deleted', result.result) unless result.result == 'deleted'

            result.total
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

            internal_exec_query(query, name, async: async)
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
              status:    query.status,
              arguments: query.arguments)

            internal_exec_query(query, name, async: async).response['count']
          end

          # returns the last inserted id from the result.
          # called through +#insert+
          def last_inserted_id(result)
            result.response['_id']
          end

          private

          # Executes the query object in the context of this connection and returns the raw result
          # from the connection adapter.
          # @param [ElasticsearchRecord::Query] query
          # @param [String (frozen),nil] name
          # @param [Boolean] async (default: false)
          # @param [Boolean] allow_retry (default: false)
          # @return [ElasticsearchRecord::Result]
          def internal_execute(query, name = nil, async: false, allow_retry: false, materialize_transactions: nil)
            # validate the query
            raise ActiveRecord::StatementInvalid, 'Unable to execute! Provided query is not a "ElasticsearchRecord::Query".' unless query.is_a?(ElasticsearchRecord::Query)
            raise ActiveRecord::StatementInvalid, 'Unable to execute! Provided query is invalid.' unless query.valid?

            # checks for write query - raises an exception if connection is locked to readonly ...
            check_if_write_query(query)

            api(*query.gate, query.query_arguments, name, async: async)
          end

          # gets called for all queries - a +ElasticsearchRecord::Query+ must be provided.
          # @param [ElasticsearchRecord::Query] query
          # @param [String (frozen),nil] name
          # @param [Array] binds - not supported on the top-level and therefore ignored!
          # @param [Boolean] prepare - used by the default AbstractAdapter - but not supported and therefore never ignored!
          # @param [Boolean] async
          # @return [ElasticsearchRecord::Result]
          def internal_exec_query(query, name = "QUERY", binds = [], prepare: false, async: false)
            build_result(
              internal_execute(query, name, async: async),
              columns: query.columns
            )
          end
        end
      end
    end
  end
end
