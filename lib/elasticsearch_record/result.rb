# frozen_string_literal: true

module ElasticsearchRecord
  class Result
    include Enumerable

    def self.empty # :nodoc:
      new(nil).freeze
    end

    attr_reader :response, :columns, :column_types

    def initialize(response, columns = [], column_types = {})
      @response = response

      # used to cast values
      @columns = columns

      @column_types = column_types
    end

    # used to resolve the response duration time
    # @return [Integer]
    def took
      response['took']
    end

    # used to resolve the total value
    # @return [Integer]
    def total
      # chop total only
      @total ||= _chop_total
    end

    # access the response RAW hits hash
    # @return [Hash]
    def hits
      response.key?('hits') ? response['hits'].with_indifferent_access : {}
    end

    # access the response RAW aggregations hash
    # @return [Hash]
    def aggregations
      response.key?('aggregations') ? response['aggregations'].with_indifferent_access : {}
    end

    # Returns true if this result set includes the column named +name+
    # used by ActiveRecord
    def includes_column?(name)
      @columns&.include?(name)
    end

    # Returns the number of elements in the response array.
    def length
      if response.key?('hits')
        response['hits']['hits'].length
      elsif response.key?('responses')
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
        results.each(&block)
      else
        results.to_enum { @results.size }
      end
    end

    # Returns true if there are no records, otherwise false.
    def empty?
      length == 0
    end

    # Returns an array of hashes representing each row record.
    def to_ary
      results
    end

    alias :to_a :to_ary

    def [](idx)
      results[idx]
    end

    # Returns the last record from the rows collection.
    def last(n = nil)
      n ? results.last(n) : results.last
    end

    def result # :nodoc:
      self
    end

    def cancel # :nodoc:
      self
    end

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

        results.map do |result|
          type.deserialize(result[key])
        end
      else
        types = if type_overrides.is_a?(Array)
                  type_overrides
                else
                  columns.map { |name| column_type(name, type_overrides) }
                end

        size = types.size

        results.map do |result|
          Array.new(size) { |i|
            key = columns[i]
            types[i].deserialize(result[key])
          }
        end
      end
    end

    private

    def column_type(name, type_overrides = {})
      type_overrides.fetch(name, Type.default_value)
    end

    # chops total value from response
    # @return [Integer]
    def _chop_total
      return self.response['total'] if self.response.key?('total')
      return self.response['hits']['total']['value'] if self.response.key?('hits')
      return self.response['aggregations'].count if self.response.key?('aggregations')

      0
    end

    # used for msearch results
    def _results_for_responses
      response['responses'].map { |response| self.class.new(response, self.columns, self.column_types) }
    end

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

    def results
      @results ||= if response.key?('hits')
                     _results_for_hits
                   elsif response.key?('responses')
                     _results_for_responses
                   else
                     []
                   end
    end
  end
end