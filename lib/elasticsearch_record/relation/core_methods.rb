module ElasticsearchRecord
  module Relation
    module CoreMethods
      def instantiate_records(rows, &block)
        # slurp the total value from the rows (rows = ElasticsearchRecord::Result)
        @total = rows.total
        super
      end

      # transforms the current relation into arel and executes the query.
      # returns the result object
      # @return [ElasticsearchRecord::Result]
      def resolve
        klass._query_by_sql(arel)
      end

      # returns the query hash for the current relation
      # @return [Hash]
      def to_query
        to_sql.arguments
      end
    end
  end
end




