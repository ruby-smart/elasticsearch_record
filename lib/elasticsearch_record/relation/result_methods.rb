module ElasticsearchRecord
  module Relation
    module ResultMethods
      # aggregate pluck provided columns.
      # returns a hash of values for each provided column
      #
      # @example
      #   Person.agg_pluck(:name)
      #   #> {"name" => ['David', 'Jeremy', 'Jose']}
      #
      #   Person.agg_pluck(:id, :name)
      #   #> {"id" => ['11', '2', '5'], "name" => ['David', 'Jeremy', 'Jose']}
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
      # @example
      #   Person.composite(:name)
      #   #> {"David" => 10, "Jeremy" => 1, "Jose" => 24}
      #
      #   Person.composite(:name, :age)
      #   #> {
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
      # resolves results (hits->hits) from the search but uses the pit query instead to resolve more than 10000 entries.
      #
      # If a block was provided it'll yield the results array per batch size.
      #
      # @param [String] keep_alive - how long to keep alive (for each single request) - default: '1m'
      # @param [Integer] batch_size - how many results per query (default: 1000 - this means at least 10 queries before reaching the +max_result_window+)
      def pit_results(keep_alive: '1m', batch_size: 1000)
        raise ArgumentError, "Batch size cannot be above the 'max_result_window' (#{klass.max_result_window}) !" if batch_size > klass.max_result_window

        # check if a limit or offset values was provided
        results_limit  = limit_value ? limit_value : Float::INFINITY
        results_offset = offset_value ? offset_value : 0

        # search_after requires a order - we resolve a order either from provided value or by default ...
        relation = ordered_relation

        # clear limit & offset
        relation.offset!(nil).limit!(nil)

        # remove the 'index' from the query arguments (pit doesn't like that)
        relation.configure!(:__claim__, { index: nil })

        # we store the results in this array
        results       = []
        results_total = 0

        # resolve a new pit and auto-close after we finished
        point_in_time(keep_alive: keep_alive) do |pit_id|
          current_pit_hash = { pit: { id: pit_id, keep_alive: keep_alive } }

          # resolve new data until we got all we need
          loop do
            # change pit settings & limit (spawn is required, since a +resolve+ will make the relation immutable)
            current_response = relation.spawn.configure!(current_pit_hash).limit!(batch_size).resolve('Pit').response

            # resolve only data from hits->hits[{_source}]
            current_results        = current_response['hits']['hits'].map { |result| result['_source'].merge('_id' => result['_id']) }
            current_results_length = current_results.length

            # check if we reached the required offset
            if results_offset < current_results_length
              # check for parts
              # (maybe a offset 6300 was provided but the batch size is 1000 - so we need to skip a part ...)
              results_from = results_offset > 0 ? results_offset : 0
              results_to   = (results_total + current_results_length - results_from) > results_limit ? results_limit - results_total + results_from - 1 : -1

              ranged_results = current_results[results_from..results_to]

              if block_given?
                yield ranged_results
              else
                results |= ranged_results
              end

              # add to total
              results_total += ranged_results.length
            end

            # -------- BREAK conditions --------

            # we reached our maximum value
            break if results_total >= results_limit

            # we ran out of data
            break if current_results_length < batch_size

            # additional security - required?
            # break if current_pit_hash[:search_after] == current_response['hits']['hits'][-1]['sort']

            # -------- NEXT LOOP changes --------

            # reduce the offset
            results_offset -= current_results_length

            # assign new pit
            current_pit_hash = { search_after: current_response['hits']['hits'][-1]['sort'], pit: { id: current_response['pit_id'], keep_alive: keep_alive } }

            # we need to justify the +batch_size+ if the query will reach over the limit
            batch_size       = results_limit - results_total if results_offset < batch_size && (results_total + batch_size) > results_limit
          end
        end

        # return results array
        results
      end

      alias_method :total_results, :pit_results

      # returns the RAW response for the current query
      # @return [Array]
      def response
        spawn.hits_only!.resolve('Response').response
      end

      # returns the RAW aggregations for the current query
      # @return [Hash]
      def aggregations
        spawn.aggs_only!.resolve('Aggregations').aggregations
      end

      # returns the response aggregations and resolve the buckets as key->value hash.
      # @return [ActiveSupport::HashWithIndifferentAccess, Hash]
      def buckets
        spawn.aggs_only!.resolve('Buckets').buckets
      end

      # returns the RAW hits for the current query
      # @return [Array]
      def hits
        spawn.hits_only!.resolve('Hits').hits
      end

      # returns the results for the current query
      # @return [Array]
      def results
        spawn.hits_only!.resolve('Results').results
      end

      # returns the total value
      def total
        loaded? ? @total : spawn.total_only!.resolve('Total').total
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