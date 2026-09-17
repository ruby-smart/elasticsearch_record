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
        initial_pit_id = klass.connection.api(:open_point_in_time, { index: klass.table_name, keep_alive: keep_alive }, "#{klass} Open Pit").dig('id')

        return initial_pit_id unless block_given?

        begin
          # block provided, so yield with id
          yield initial_pit_id
        rescue ::Exception
          # IMPORTANT: the PIT must be closed even if the block raised - it holds open search
          # contexts on EVERY shard until its +keep_alive+ expires, and a loop that dies halfway
          # through (see @ #pit_results) would otherwise leak one per attempt.
          #
          # A failure of the close itself is swallowed here on purpose: raising from this path
          # would REPLACE the exception that actually caused the abort with a follow-up error.
          begin
            _close_point_in_time(initial_pit_id)
          rescue ::StandardError
            nil
          end

          raise
        end

        # close PIT
        _close_point_in_time(initial_pit_id)

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
      # @return [Integer, Array] either returns the results-array (no block provided) or the total amount of results
      def pit_results(keep_alive: '1m', batch_size: 1000)
        raise(ArgumentError, "Batch size cannot be above the 'max_result_window' (#{batch_size} > #{klass.max_result_window}) !") if batch_size > klass.max_result_window

        # check if limit or offset values where provided
        results_limit = limit_value ? limit_value : Float::INFINITY
        results_offset = offset_value ? offset_value : 0

        # search_after requires a order - we resolve a order either from provided value or by default ...
        relation = ordered_relation

        # FALLBACK (without any order) for restricted access to the '_id' field.
        # with PIT a order by '_shard_doc' can also be used
        # see @ https://www.elastic.co/guide/en/elasticsearch/reference/current/paginate-search-results.html
        relation.order!(_shard_doc: :asc) if relation.order_values.empty? && klass.connection.access_shard_doc?

        # clear limit & offset
        relation.offset!(nil).limit!(nil)

        # remove the 'index' from the query arguments (pit doesn't like that)
        relation.configure!(:__query__, { index: nil })

        # we store the results in this array
        results = []
        results_total = 0

        # resolve a new pit and auto-close after we finished
        point_in_time(keep_alive: keep_alive) do |pit_id|
          # set the initial pit hash, used to configure the ES query
          current_pit_hash = { pit: { id: pit_id, keep_alive: keep_alive } }

          # resolve new data until we got all we need
          loop do
            # change pit settings & limit (spawn is required, since a +resolve+ will make the relation immutable)
            # @type [ElasticsearchRecord::Result]
            current_result = relation.spawn.configure!(current_pit_hash).limit!(batch_size).resolve('Pit Results')

            # resolve all results, depending on the existing query (select, ...)
            current_results = current_result.to_ary

            # temporary store the absolute length - used for pagination or stop
            current_results_length = current_results.length

            # check if we reached the required offset
            if results_offset < current_results_length
              # check for parts
              # (maybe an offset of 6300 was provided but the batch size is 1000 - so we need to skip a part ...)
              results_from = results_offset > 0 ? results_offset : 0
              results_to = (results_total + current_results_length - results_from) > results_limit ? results_limit - results_total + results_from - 1 : -1

              # reduce the *current_results* by calculated +from..to+ range
              current_results = current_results[results_from..results_to] if results_from != 0 || results_to != -1

              if block_given?
                yield current_results
              else
                results += current_results
              end

              # add to total
              results_total += current_results.length
            end

            # -- BREAK conditions --------------------------------------------------------------------------------------

            # we reached our maximum value
            break if results_total >= results_limit

            # we ran out of data
            break if current_results_length < batch_size

            # the cursor of the NEXT batch: the sort values of the last hit, plus the (possibly
            # refreshed) pit id.
            # IMPORTANT: both are read defensively - a response without a 'sort' (the order was
            # silently dropped) or without a 'pit_id' would raise a bare NoMethodError deep inside
            # the loop, which says nothing about the actual cause.
            next_search_after = current_result.response.dig('hits', 'hits', -1, 'sort')
            next_pit_id       = current_result.response['pit_id']

            if next_search_after.blank? || next_pit_id.blank?
              raise(::ActiveRecord::StatementInvalid,
                    "'pit_results' aborted - the response carries no #{next_search_after.blank? ? "'sort' values (missing order)" : "'pit_id'"}")
            end

            # additional security - prevents infinite loops
            if current_pit_hash[:search_after] == next_search_after && current_pit_hash[:pit][:id] == next_pit_id
              raise(::ActiveRecord::StatementInvalid, "'pit_results' aborted due an infinite loop error (invalid or missing order)")
            end

            # -- NEXT LOOP changes -------------------------------------------------------------------------------------

            # reduce the offset
            results_offset -= current_results_length

            # assign new pit
            current_pit_hash = { search_after: next_search_after, pit: { id: next_pit_id, keep_alive: keep_alive } }

            # we need to justify the +batch_size+ if the query reaches over the limit
            batch_size = results_limit - results_total if results_offset < batch_size && (results_total + batch_size) > results_limit
          end
        end

        # returns either to total number of +pit+ results or an array of all collected results
        if block_given?
          results_total
        else
          results
        end
      end

      alias_method :total_results, :pit_results

      # executes a delete query in a +point_in_time+ scope.
      # this will provide the possibility to delete more than the +max_result_window+ (default: 10000) docs in a batched process.
      # @param [String] keep_alive - defines the keep alive time per +pit+ (not in total) - should be relative to *batch_size*
      # @param [Integer] batch_size - the size of entries to delete per +pit+
      # @param [Boolean] refresh - auto-refresh index after delete finished (default: true)
      # @return [Integer] total amount of deleted docs
      def pit_delete(keep_alive: '1m', batch_size: 1_000, refresh: true)
        # spawns a new query with disabled results (so only ids will be resolved)
        delete_count = spawn.meta_only!.pit_results(keep_alive: keep_alive, batch_size: batch_size) do |results|
          # skip empty results
          next unless results.any?

          # delete all IDs through +API+
          # does not refresh index at this point (this is done below, if not disabled)
          klass.connection.api(:bulk, { index: klass.table_name, body: results.map { |result| { delete: { _id: result['_id'] } } }, refresh: false }, "#{klass} Pit Delete")
        end

        # refresh index
        klass.connection.refresh_table(klass.table_name) if refresh

        # return total count
        delete_count
      end

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
      #
      # IMPORTANT: elasticsearch stops counting at +index.max_result_window+ (10.000 by default) and
      # then reports a LOWER BOUND instead of an exact count - so a returned 10.000 may well mean
      # "10.000 or more". Use +total_exact?+ to tell the two apart, or +count+, which resolves the
      # real number through the +_count+ API.
      # see @ ElasticsearchRecord::Result#total
      def total
        loaded? ? @total : spawn.total_only!.resolve('Total').total
      end

      # true unless the resolved +total+ is only a lower bound.
      # see @ ElasticsearchRecord::Result#total_exact?
      def total_exact?
        spawn.total_only!.resolve('Total').total_exact?
      end

      # returns the relation of the resolved +total+ - either 'eq', 'gte' or nil.
      # see @ ElasticsearchRecord::Result#total_relation
      def total_relation
        spawn.total_only!.resolve('Total').total_relation
      end

      # sets query as "hits"-only query (drops the aggs from the query)
      # @return [self]
      def hits_only!
        configure!({ aggs: nil })
      end

      # sets query as "aggs"-only query (drops the size & sort options - so no hits will return)
      # @return [self]
      def aggs_only!
        configure!({ size: 0, from: nil, sort: nil, _source: false })
      end

      # sets query as "total"-only query (drops the size, sort & aggs options - so no hits & aggs will be returned)
      # @return [self]
      def total_only!
        configure!({ size: 0, from: nil, aggs: nil, sort: nil, _source: false })
      end

      # sets query as "meta"-only query (drops aggs and source).
      # This is used to prevent resolving documents from the index and only returns "meta" information (like _id, _score, _type, ...)
      # @return [self]
      def meta_only!
        select(::ElasticsearchRecord::Query::COLUMNS_NONE).configure!({ aggs: nil, _source: false })
      end

      private

      # closes the provided point in time.
      # see @ #point_in_time
      # @param [String] pit_id
      def _close_point_in_time(pit_id)
        klass.connection.api(:close_point_in_time, { body: { id: pit_id } }, "#{klass} Close Pit")
      end
    end
  end
end