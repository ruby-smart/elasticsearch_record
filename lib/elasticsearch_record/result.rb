# frozen_string_literal: true

require "active_record/future_result"

module ElasticsearchRecord
  class Result
    include Enumerable

    # creates an empty response
    # @return [ElasticsearchRecord::Result (frozen), ActiveRecord::FutureResult::Complete (frozen)]
    def self.empty(async: false)
      if async
        EMPTY_ASYNC
      else
        EMPTY
      end
    end

    attr_reader :response, :columns, :column_types

    # initializes a new result object
    # @param [Elasticsearch::API::Response, Object, nil] response
    # @param [Array] columns
    # @param [Hash] column_types
    def initialize(response, columns = [], column_types = {})
      # contains either the response or creates an empty hash (if nil)
      @response = response.presence || {}

      # used to build computed_results
      @columns = columns

      # used to cast values
      @column_types = column_types
    end

    # returns the response duration time
    # @return [Integer]
    def took
      response['took']
    end

    # returns the response result string
    # @return [String]
    def result
      response['result'] || ''
    end

    # returns the response total value.
    # either chops the +total+ value directly from response, from hits or aggregations.
    # @return [Integer]
    def total
      # chop total from response and not from the generated data
      @total ||= _total
    end

    # Returns the RAW +_source+ data from each hit.
    # PLEASE NOTE: The array will only contain the RAW data from each +_source+ (meta info like '_id' or '_score' are not included)
    # @return [Array]
    def results
      # IMPORTANT: check against missing hits without any '_source' node.
      # This happens if the Elasticsearch query has the  +_source:false+ flag!
      if response['hits']
        response['hits']['hits'].map { |doc| doc['_source'] || {} }
      elsif _tabular?
        # a tabular (+SQL+ / +ES|QL+) response has no '_source' node - the row values are the data
        _results_from_tabular
      else
        []
      end
    end

    # returns an array of all rows.
    # => All result values, depending on the provided columns.
    # The +rows+ is used by the ActiveRecord ConnectionAdapters and must not be removed!
    # @return [Array]
    def rows
      # a tabular (+SQL+ / +ES|QL+) response is ALREADY positional - and it is positional to the
      # response's own columns, not to the (requested) +columns+ of the query.
      return _tabular_values if _tabular?

      # IMPORTANT: without provided +columns+ we cannot build positional rows - mapping over an
      # empty +columns+ array would return an empty array per hit and silently lose all data.
      # In this case we fall back to the raw +_source+ values.
      return results.map(&:values) if columns.blank?

      results.map { |doc|
        columns.map { |column|
          doc[column]
        }
      }
    end

    # returns the response RAW hits hash.
    # PLEASE NOTE: Does not return the nested hits (+response['hits']['hits']+) array!
    #
    # @return [ActiveSupport::HashWithIndifferentAccess, Hash]
    def hits
      response['hits']&.with_indifferent_access || {}
    end

    # returns the response RAW aggregations hash.
    # @return [ActiveSupport::HashWithIndifferentAccess, Hash]
    def aggregations
      response['aggregations']&.with_indifferent_access || {}
    end

    # returns the (nested) bucket values (and aggregated values) from the response aggregations.
    # @return [ActiveSupport::HashWithIndifferentAccess]
    def buckets
      # aggregations are already a hash with key => data, but to prevent reference manipulation on the hash
      # we have to create a new one here...
      aggregations.reduce({}) { |buckets, (key, agg)|
        buckets[key] = _resolve_bucket(agg)
        buckets
      }.with_indifferent_access
    end

    # Returns true if this result set includes the column named +name+.
    # used by +ActiveRecord+
    def includes_column?(name)
      @columns&.include?(name)
    end

    # Returns the number of elements in the response array.
    # Either uses the +hits+ length, the +responses+ length _(msearch)_ or the length of the
    # tabular value rows _(SQL / ES|QL)_.
    # @return [Integer]
    def length
      if response.key?('hits')
        response['hits']['hits'].length
      elsif response.key?('responses')
        # used by +msearch+
        response['responses'].length
      elsif _tabular?
        # used by +sql+ & +esql+
        _tabular_values.length
      else
        0
      end
    end

    # Calls the given block once for each element in row collection, passing
    # row as parameter.
    #
    # Returns an +Enumerator+ if no block is given.
    def each(&block)
      if block_given?
        computed_results.each(&block)
      else
        computed_results.to_enum { @computed_results.size }
      end
    end

    # Returns true if there are no records, otherwise false.
    def empty?
      length == 0
    end

    # Returns an array of hashes representing each row record.
    def to_ary
      computed_results
    end

    alias :to_a :to_ary

    def [](idx)
      computed_results[idx]
    end

    # Returns the last record(s) from the *computed_results* collection.
    def last(n = nil)
      n ? computed_results.last(n) : computed_results.last
    end

    # used by ActiveRecord
    def cancel # :nodoc:
      self
    end

    # used by ActiveRecord for "pluck"
    def cast_values(type_overrides = {})
      # fast escape, if no hits are available
      return [] unless response['hits']

      # HINT: This is separated to avoid allocating a (nested) array per row
      if columns.one?
        # resolve the column key
        key = columns.first

        # resolve type from overrides or +#column_type+ method
        type = type_overrides.is_a?(Array) ? type_overrides.first : column_type(key, type_overrides)

        # EDGE-case for metadata fields
        if ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.metadata_keys.include?(key)
          # directly read from doc
          response['hits']['hits'].map { |doc| type.deserialize(doc[key]) }
        else
          results.map do |result|
            type.deserialize(result[key])
          end
        end
      else
        # resolve types from overrides or +#column_type+ method
        types = type_overrides.is_a?(Array) ? type_overrides : columns.map { |name| column_type(name, type_overrides) }

        size = types.size

        # EDGE-case for metadata fields - they have to be resolved from the doc, so we merge them into the +_source+
        rows = if (ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.metadata_keys & columns).any?
                 response['hits']['hits'].map { |doc|
                   (doc['_source'] || {}).merge(doc.slice(*ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.metadata_keys))
                 }
               else
                 response['hits']['hits'].map { |doc| doc['_source'] || {} }
               end

        rows.map do |result|
          Array.new(size) { |i|
            types[i].deserialize(result[columns[i]])
          }
        end
      end
    end

    private

    # used by ActiveRecord
    def column_type(name, type_overrides = {})
      type_overrides.fetch(name, ::ActiveRecord::Type.default_value)
    end

    # resolves total value from response
    # @return [Integer]
    def _total
      return self.response['total'] if self.response.key?('total')
      return self.response['hits']['total']['value'] if self.response.key?('hits')
      return self.response['aggregations'].count if self.response.key?('aggregations')
      # a tabular response has no total - the transferred rows are all there is
      return _tabular_values.length if _tabular?

      0
    end

    # true if the response is TABULAR - which is what the +sql+ & +esql+ APIs return instead of a
    # (nested) 'hits' node: a flat 'columns' definition and positional value rows.
    # @return [Boolean]
    def _tabular?
      response.key?('columns') && (response.key?('rows') || response.key?('values'))
    end

    # returns the column names of a tabular response.
    # Both APIs describe their columns as a {'name' =>, 'type' =>} pair.
    # @return [Array<String>]
    def _tabular_columns
      response['columns'].map { |column| column['name'] }
    end

    # returns the positional value rows of a tabular response.
    # PLEASE NOTE: the +sql+ API names this node 'rows', the +esql+ API names it 'values'.
    # @return [Array<Array>]
    def _tabular_values
      response['rows'] || response['values']
    end

    # used for +sql+ & +esql+ results
    # IMPORTANT: the rows are positional to the RESPONSE columns - not to the (requested) +columns+
    # of the query. A projecting query (e.g. 'SELECT name FROM ...') returns fewer columns, so
    # zipping against the query's columns would shift every value.
    # @return [Array]
    def _results_from_tabular
      # We freeze the strings to prevent them getting duped when
      # used as keys in ActiveRecord::Base's @attributes hash.
      keys = _tabular_columns.map(&:-@)

      _tabular_values.map { |row| keys.zip(row).to_h }
    end

    # used for +msearch+ results
    # @return [Array]
    def _results_from_responses
      response['responses'].map { |response| self.class.new(response, self.columns, self.column_types) }
    end

    # used for +search+ results
    # @return [Array]
    def _results_from_hits
      # PLEASE NOTE: the 'hits' response has multiple nodes: BASE nodes & the +_source+ node.
      # The real data is within the source node, but we also want the METADATA nodes for possible score & type check
      metadata_fields = ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.metadata_keys

      # check for provided columns
      if @columns.present?
        # We freeze the strings to prevent them getting duped when
        # used as keys in ActiveRecord::Base's @attributes hash.
        # IMPORTANT: remove *metadata_fields* from possible provided columns ( &:-@ -> freeze strings )
        columns = (@columns - metadata_fields).map(&:-@)

        # this is the hashed result array
        response['hits']['hits'].map { |doc|
          # allocate new result hash with all known metadata keys ('_id', ...)
          result = doc.slice(*metadata_fields)

          # iterate through each requested column
          columns.each do |column|
            # in case no source was provided, it prevents an exception
            result[column] = doc.dig('_source', column)
          end

          result
        }
      else
        # if we don't have any columns we just resolve the _source data as it is
        # this might end up in unknown (but mapped) attributes (if they are stored as nil in ES)

        # this is the hashed result array
        response['hits']['hits'].map { |doc|
          # in case no source was provided, it prevents an exception
          doc.slice(*metadata_fields).merge!(doc['_source'] || {})
        }
      end
    end

    # resolves bucket nodes recursively
    # @param [Object] node
    # @return [Object]
    def _resolve_bucket(node)
      # check, if node is not a hash - in this case we just return it's value
      return node unless node.is_a?(Hash)

      # check if the node has a bucket
      if node.key?(:buckets)
        node[:buckets].reduce({}) { |m, b|
          # buckets can be a Hash or Array (of Hashes)
          bucket_key, bucket = b.is_a?(Hash) ? [b[:key], b] : b

          m[bucket_key] = _resolve_bucket(bucket)
          m
        }
      elsif node.key?(:value)
        node[:value]
      elsif node.key?(:values)
        node[:values]
      else
        # resolve sub-aggregations / nodes without 'meta' keys.
        # if this results in an empty hash, the return will be nil
        node.except(:key, :doc_count, :doc_count_error_upper_bound, :sum_other_doc_count, :key_as_string).transform_values { |val| _resolve_bucket(val) }.presence
      end
    end

    # builds computed results (used to build ActiveRecord models)
    # @return [Array]
    def computed_results
      @computed_results ||= if response.key?('hits')
                              _results_from_hits
                            elsif response.key?('responses')
                              # used by +msearch+
                              _results_from_responses
                            elsif _tabular?
                              # used by +sql+ & +esql+
                              _results_from_tabular
                            else
                              []
                            end
    end

    EMPTY = new([].freeze, [].freeze, {}.freeze).freeze
    private_constant :EMPTY

    EMPTY_ASYNC = ::ActiveRecord::FutureResult::Complete.new(EMPTY).freeze
    private_constant :EMPTY_ASYNC
  end
end