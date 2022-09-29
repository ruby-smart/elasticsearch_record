module ElasticsearchRecord
  module Relation
    module ResultMethods
      # aggregate pluck provided columns.
      # returns a hash of values for each provided column
      #
      # Person.agg_pluck(:name)
      # => {"name" => ['David', 'Jeremy', 'Jose']}
      #
      # Person.agg_pluck(:id, :name)
      # => {"id" => ['11', '2', '5'], "name" => ['David', 'Jeremy', 'Jose']}
      #
      # @param [Array] column_names
      # @return [Hash]
      def agg_pluck(*column_names)
        scope = self.spawn

        column_names.each do |column_name|
          scope.aggregate!(column_name, { terms: { field: column_name, size: limit_value || 10 } })
        end

        scope.aggregations.reduce({}) { |m, (k, v)|
          m[k.to_s] = v[:buckets].map { |bucket| bucket[:key] }
          m
        }
      end

      # A multi-bucket aggregation that creates composite buckets from different sources.
      # PLEASE NOTE: The composite aggregation is expensive. Load test your application
      # before deploying a composite aggregation in production!
      #
      # For a single column_name a hash with the distinct key and the +doc_count+ as value is returned.
      # For multiple column_names a hash with the distinct keys (as hash) and the +doc_count+ as value is returned.
      #
      # Person.composite(:name)
      # => {"David" => 10, "Jeremy" => 1, "Jose" => 24}
      #
      # Person.composite(:name, :age)
      # => {
      #       {name: "David", age: "16"} => 3,
      #       {name: "David", age: "18"} => 6,
      #       {name: "David", age: "20"} => 1,
      #       {name: "Jeremy", age: "20"} => 1,
      #       {name: "Jose", age: "6"} => 2,
      #       ...
      #    }
      # @param [Array] column_names
      # @return [Hash]
      def composite(*column_names)
        scope = self.spawn
        scope.aggregate!(:composite_bucket, { composite: { size: limit_value || 10, sources: column_names.map { |column_name| { column_name => { terms: { field: column_name } } } } } })

        if column_names.size == 1
          column_name = column_names[0]
          scope.aggregations[:composite_bucket][:buckets].reduce({}) { |m, bucket| m[bucket[:key][column_name]] = bucket[:doc_count]; m }
        else
          scope.aggregations[:composite_bucket][:buckets].reduce({}) { |m, bucket| m[bucket[:key]] = bucket[:doc_count]; m }
        end
      end

      # creates and returns a new point in time id.
      # optionally yields the provided block and closes the pit afterwards.
      # @param [String] keep_alive (default: '1m')
      # @return [nil, String] - either returns the pit_id (no block given) or nil
      def point_in_time(keep_alive: '1m')
        # resolve a initial PIT id
        initial_pit_id = klass.connection.api(:core, :open_point_in_time, { index: klass.table_name, keep_alive: keep_alive }, "#{klass} Open Pit").dig('id')

        return initial_pit_id unless block_given?

        # block provided, so yield with id
        yield initial_pit_id

        # close PIT
        klass.connection.api(:core, :close_point_in_time, { body: { id: initial_pit_id } }, "#{klass} Close Pit")

        # return nil if everything was ok
        nil
      end

      alias_method :pit, :point_in_time

      # executes the current query in a +point_in_time+ scope.
      # this will provide the possibility to resolve more than the +max_result_window+ (default: 10000) hits.
      # resolves results (hits->hits) from the search but uses the pit query instead to resolve more than 10000 entries
      # @param [String] keep_alive - how long to keep alive (for each single request) - default: '1m'
      # @param [Integer] batch_size - how many results per query (default: 1000 - this means at least 10 queries before reaching the +max_result_window+)
      def pit_results(keep_alive: '1m', batch_size: 1000)
        # store a maximum limit value as break condition
        maximum_results = limit_value ? limit_value : Float::INFINITY

        # search_after requires a order
        relation = ordered_relation

        # clear limit & offset
        relation.offset!(nil).limit!(nil)

        # remove the 'index' from the query arguments (pit doesn't like that)
        relation.configure!(:__query__, { index: nil })

        # prepare a total results array
        results       = []
        results_total = 0

        # resolve a new pit and auto-close after we finished
        point_in_time(keep_alive: keep_alive) do |pit_id|
          current_pit_hash = { pit: { id: pit_id, keep_alive: keep_alive } }

          loop do
            # we need to justify the +batch_size+ if the query will reach over the limit
            batch_size = maximum_results - results_total if (results_total + batch_size) > maximum_results

            # change pit settings & limit (spawn is required, since a +resolve+ will make the relation immutable)
            current_response = relation.spawn.configure!(current_pit_hash).limit!(batch_size).resolve('Pit').response

            # resolve only data from hits->hits[{_source}]
            current_results        = current_response['hits']['hits'].map { |result| result['_source'] }
            current_results_length = current_results.length

            # add current results to return array
            results       |= current_results
            results_total += current_results_length

            # BREAK conditions
            break if current_results_length < batch_size
            break if results_total >= maximum_results
            # break if current_pit_hash[:search_after] == current_response['hits']['hits'][-1]['sort'] # additional security - required?

            # assign new pit
            current_pit_hash = { search_after: current_response['hits']['hits'][-1]['sort'], pit: { id: current_response['pit_id'], keep_alive: keep_alive } }
          end
        end

        # return results
        results
      end

      alias_method :total_results, :pit_results

      # returns the RAW response for the current query
      # @return [Array]
      def response
        spawn.hits_only!.resolve.response
      end

      # returns the RAW aggregations for the current query
      # @return [Hash]
      def aggregations
        spawn.aggs_only!.resolve.aggregations
      end

      # returns the RAW hits for the current query
      # @return [Array]
      def hits
        spawn.hits_only!.resolve.hits
      end

      # returns the results for the current query
      # @return [Array]
      def results
        spawn.hits_only!.resolve.results
      end

      # returns the total value
      def total
        loaded? ? @total : spawn.total_only!.resolve.total
      end

      # sets query as "hits"-only query (drops the aggs from the query)
      def hits_only!
        configure!({ aggs: nil })

        self
      end

      # sets query as "aggs"-only query (drops the size & sort options - so no hits will return)
      def aggs_only!
        configure!({ size: 0, from: nil, sort: nil, _source: false })

        self
      end

      # sets query as "total"-only query (drops the size, sort & aggs options - so no hits & aggs will be returned)
      def total_only!
        configure!({ size: 0, from: nil, aggs: nil, sort: nil, _source: false })

        self
      end
    end
  end
end