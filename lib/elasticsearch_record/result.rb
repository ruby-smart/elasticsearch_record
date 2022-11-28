# frozen_string_literal: true

module ElasticsearchRecord
  class Result
    include Enumerable

    # creates an empty response
    # @return [ElasticsearchRecord::Result (frozen)]
    def self.empty
      new(nil).freeze
    end

    attr_reader :response, :columns, :column_types

    # initializes a new result object
    # @param [Elasticsearch::API::Response, Object, nil] response
    # @param [Array] columns
    # @param [Hash] column_types
    def initialize(response, columns = [], column_types = {})
      # contains either the response or creates a empty hash (if nil)
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

    # returns the response total value.
    # either chops the +total+ value directly from response, from hits or aggregations.
    # @return [Integer]
    def total
      # chop total only
      @total ||= _chop_total
    end

    # returns the response RAW hits hash.
    # PLEASE NOTE: Does not return the nested hits (+response['hits']['hits']+) array!
    # @return [ActiveSupport::HashWithIndifferentAccess, Hash]
    def hits
      response.key?('hits') ? response['hits'].with_indifferent_access : {}
    end

    # Returns the RAW values from the hits - aka. +rows+.
    # PLEASE NOTE: The array will only contain the RAW data from each +_source+ (meta info like '_score' is not included)
    # The +rows+ alias use used by the ActiveRecord ConnectionAdapters and must not be removed!
    # @return [Array]
    def results
      return [] unless response['hits']

      response['hits']['hits'].map { |result| result['_source'] }
    end

    alias_method :rows, :results

    # returns the response RAW aggregations hash.
    # @return [ActiveSupport::HashWithIndifferentAccess, Hash]
    def aggregations
      response.key?('aggregations') ? response['aggregations'].with_indifferent_access : {}
    end

    # returns the (nested) bucket values (and aggregated values) from the response aggregations.
    # @return [ActiveSupport::HashWithIndifferentAccess]
    def buckets
      # aggregations are already a hash with key => data, but to prevent reference manipulation on the hash
      # we have to create a new one here...
      aggregations.reduce({}) { |buckets, (key, agg)|
        # check if this agg has a bucket
        if agg.key?(:buckets)
          buckets[key] = agg[:buckets].reduce({}) { |m, b|
            # buckets can be a Hash or Array (of Hashes)
            bucket_key, bucket = b.is_a?(Hash) ? [b[:key], b] : b
            m[bucket_key]      = bucket.except(:key, :doc_count).transform_values { |val| val[:value] }

            m
          }
        elsif agg.key?(:value)
          buckets[key] = agg[:value]
        elsif agg.key?(:values)
          buckets[key] = agg[:values]
        end

        buckets
      }.with_indifferent_access
    end

    # Returns true if this result set includes the column named +name+.
    # used by ActiveRecord
    def includes_column?(name)
      @columns&.include?(name)
    end

    # Returns the number of elements in the response array.
    # Either uses the +hits+ length or the +responses+ length _(msearch)_.
    # @return [Integer]
    def length
      if response.key?('hits')
        response['hits']['hits'].length
      elsif response.key?('responses')
        # used by +msearch+
        response['responses'].length
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

    # Returns the last record from the rows collection.
    def last(n = nil)
      n ? computed_results.last(n) : computed_results.last
    end

    # returns the response result string
    # @return [String]
    def result
      response['result'] || ''
    end

    # used by ActiveRecord
    def cancel # :nodoc:
      self
    end

    # used by ActiveRecord
    def cast_values(type_overrides = {})
      # :nodoc:
      if columns.one?
        # Separated to avoid allocating an array per row
        key = columns.first

        type = if type_overrides.is_a?(Array)
                 type_overrides.first
               else
                 column_type(columns.first, type_overrides)
               end

        computed_results.map do |result|
          type.deserialize(result[key])
        end
      else
        types = if type_overrides.is_a?(Array)
                  type_overrides
                else
                  columns.map { |name| column_type(name, type_overrides) }
                end

        size = types.size

        computed_results.map do |result|
          Array.new(size) { |i|
            key = columns[i]
            types[i].deserialize(result[key])
          }
        end
      end
    end

    private

    # used by ActiveRecord
    def column_type(name, type_overrides = {})
      type_overrides.fetch(name, Type.default_value)
    end

    # chops total value from response
    # @return [Integer]
    def _chop_total
      return self.response['total'] if self.response.key?('total')
      return self.response['hits']['total']['value'] if self.response.key?('hits')
      return self.response['aggregations'].count if self.response.key?('aggregations')
      return self.response['_shards']['total'] if self.response.key?('_shards')

      0
    end

    # used for +msearch+ results
    # @return [Array]
    def _results_for_responses
      response['responses'].map { |response| self.class.new(response, self.columns, self.column_types) }
    end

    # used for +search+ results
    # @return [Array]
    def _results_for_hits
      # PLEASE NOTE: the 'hits' response has multiple nodes: BASE nodes & the +_source+ node.
      # The real data is within the source node, but we also want the BASE nodes for possible score & type check
      base_fields = ActiveRecord::ConnectionAdapters::ElasticsearchAdapter.base_structure_keys

      # check for provided columns
      if @columns.present?
        # We freeze the strings to prevent them getting duped when
        # used as keys in ActiveRecord::Base's @attributes hash.
        # ALSO IMPORTANT: remove base_fields from possible provided columns
        columns = @columns ? (@columns - base_fields).map(&:-@) : []

        # this is the hashed result array
        response['hits']['hits'].map { |doc|
          result = doc.slice(*base_fields)
          columns.each do |column|
            result[column] = doc['_source'][column]
          end

          result
        }
      else
        # if we don't have any columns we just resolve the _source data as it is
        # this might end up in unknown (but mapped) attributes (if they are stored as nil in ES)

        # this is the hashed result array
        response['hits']['hits'].map { |doc|
          doc.slice(*base_fields).merge(doc['_source'])
        }
      end
    end

    # builds computed results (used to build ActiveRecord models)
    # @return [Array]
    def computed_results
      @computed_results ||= if response.key?('hits')
                              _results_for_hits
                            elsif response.key?('responses')
                              # used by +msearch+
                              _results_for_responses
                            else
                              []
                            end
    end
  end
end