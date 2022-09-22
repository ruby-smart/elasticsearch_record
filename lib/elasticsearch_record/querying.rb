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

      # finds records by query
      def find_by_query(query_arguments, binds = [], preparable: nil, &block)
        # build new query
        query = ElasticsearchRecord::Query.new(
          index: table_name,
          type:  ElasticsearchRecord::Query::TYPE_SEARCH,
          body:  query_arguments,
          # IMPORTANT: Always provide all columns
          columns: source_column_names)

        find_by_sql(query, binds, preparable: preparable, &block)
        # vs
        # connection.exec_query(query, "#{name} Search", binds, prepare: preparable, async: async)
      end

      # executes a msearch by provided +RAW+ queries
      def msearch(queries, binds = [], preparable: nil, async: false)
        # build new msearch query
        query = ElasticsearchRecord::Query.new(
          index: table_name,
          type:  ElasticsearchRecord::Query::TYPE_MSEARCH,
          body:  queries.map { |q| { search: q } },
          # IMPORTANT: Always provide all columns
          columns: source_column_names)

        connection.exec_query(query, "#{name} Msearch", binds, prepare: preparable, async: async)
      end

      # queries by msearch
      def _query_by_msearch(queries, binds = [], preparable: nil, async: false)
        connection.select_multiple(queries, "#{name} Msearch", binds, preparable: preparable, async: async)
      end
    end
  end
end
