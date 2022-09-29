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

      # returns the first instance by provided id
      # overwritten to prevent (currently) unsupported +cached_find_by_statement+
      def find(*ids)
        return super unless ids.length == 1
        return super if block_given? || primary_key.nil? || scope_attributes?

        id  = ids.first
        key = primary_key

        where(key => id).first ||
          raise(::ActiveRecord::RecordNotFound.new("Couldn't find #{name} with '#{key}'=#{id}", name, key, id))
      end

      # returns the first instance by provided key
      # overwritten to prevent (currently) unsupported +cached_find_by_statement+
      def find_byX(*args)
        return super if scope_attributes?

        hash = args.first
        return super unless Hash === hash

        hash = hash.each_with_object({}) do |(key, value), h|
          key   = key.to_s
          key   = attribute_aliases[key] || key
          value = value.id if value.respond_to?(:id)

          h[key] = value
        end

        statement = where(hash).limit(1)

        begin
          statement.first
        rescue TypeError
          raise ::ActiveRecord::StatementInvalid
        end
      end

      def find_by(*args) # :nodoc:
        return super if scope_attributes?

        hash = args.first
        return super unless Hash === hash

        hash = hash.each_with_object({}) do |(key, value), h|
          key = key.to_s
          key = attribute_aliases[key] || key

          return super if reflect_on_aggregation(key)

          reflection = _reflect_on_association(key)

          if !reflection
            value = value.id if value.respond_to?(:id)
          elsif reflection.belongs_to? && !reflection.polymorphic?
            key = reflection.join_foreign_key
            pkey = reflection.join_primary_key
            value = value.public_send(pkey) if value.respond_to?(pkey)
          end

          if !columns_hash.key?(key) || StatementCache.unsupported_value?(value)
            return super
          end

          h[key] = value
        end

        keys = hash.keys
        statement = cached_find_by_statement(keys) { |params|
          wheres = keys.index_with { params.bind }
          Debugger.debug(wheres,"wheres")
          Debugger.debug(hash.values,"hash.values")
          x = where(wheres).limit(1)

          Debugger.debug(x.arel.ast,"xxxxxxxxxxxxxxxxxxxxx")
          x
        }
        Debugger.debug(statement,"statement")

        begin
          statement.execute(hash.values, connection).first
        rescue TypeError
          raise ActiveRecord::StatementInvalid
        end
      end






      # finds records by sql, query-arguments or query-object.
      #
      # PLEASE NOTE: This method is used by different other methods:
      # - ActiveRecord::Relation#exec_queries
      # - ActiveRecord::StatementCache#execute
      # - <directly on demand>
      #
      # We cannot rewrite all locations since this will mess up the whole logic end will end in other problems.
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

      # execute query by msearch
      def _query_by_msearch(queries, async: false)
        connection.select_multiple(queries, "#{name} Msearch", async: async)
      end
    end
  end
end
