module ElasticsearchRecord
  module Relation
    module CoreMethods
      def instantiate_records(rows, &block)
        # slurp the total value from the rows (rows = ElasticsearchRecord::Result)
        @total = rows.total
        super
      end

      # transforms the current relation into arel, compiles it to query and executes the query.
      # returns the result object.
      #
      # PLEASE NOTE: This makes the query +immutable+ and raises a +ActiveRecord::ImmutableRelation+
      # if you try to change it's values.
      #
      # PLEASE NOTE: resolving records _(instantiate)_ is never possible after calling this method!
      #
      # @return [ElasticsearchRecord::Result]
      # @param [String] name - custom instrumentation name (default: 'Load')
      def resolve(name = 'Load')
        # this acts the same like +#_query_by_sql+ but we can customize the instrumentation name and
        # do not store the records.
        klass.connection.select_all(arel, "#{klass.name} #{name}")
      end

      # returns the query hash for the current relation
      # @return [Hash]
      def to_query
        to_sql.arguments
      end

      # executes the elasticsearch msearch on the related klass
      #
      # @example
      #   msearch([2020, 2019, 2018]).each{ |q, year| q.where!(year: year) }
      #
      # @param [Array] values - values to be yielded
      # @param [nil, Symbol] response_type - optional type of search response (:took, :total , :hits , :aggregations , :length , :results, :each)
      def msearch(values = nil, response_type = nil)
        if values.nil?
          arels = [arel]
        else
          arels = values.map { |value|
            # spawn a new relation and return the arel-object
            yield(spawn, value).arel
          }
        end

        # returns a response object with multiple single responses
        responses = klass._query_by_msearch(arels)

        if response_type
          responses.map(&response_type.to_sym)
        else
          responses
        end
      end
    end
  end
end




