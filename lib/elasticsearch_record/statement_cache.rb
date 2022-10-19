# frozen_string_literal: true

module ElasticsearchRecord
  class StatementCache < ActiveRecord::StatementCache

    class PartialQuery < ActiveRecord::StatementCache::PartialQuery # :nodoc:
      def initialize(values)
        @values = values
        # no need to create indexes
      end

      def sql_for(binds, connection)
        # dup original array
        claims = @values.deep_dup

        # substitute binds
        claims.each do |claim|
          # action, args = claim
          claim[1] = deep_substitute_binds(claim[1], binds, connection)
        end

        # build a new query collector
        collector = ::Arel::Collectors::ElasticsearchQuery.new

        claims.each do |claim|
          collector << claim
        end

        collector
      end

      private

      def deep_substitute_binds(thing, binds, connection)
        if thing.is_a?(ActiveRecord::StatementCache::Substitute)
          value = binds.shift
          if ActiveModel::Attribute === value
            value = value.value_for_database
          end
          connection.quote(value)
        elsif thing.is_a?(Hash)
          thing.transform_values { |val|
            deep_substitute_binds(val, binds, connection)
          }
        elsif thing.is_a?(Array)
          thing.map { |val|
            deep_substitute_binds(val, binds, connection)
          }
        else
          thing
        end
      end
    end

    class PartialQueryCollector < ActiveRecord::StatementCache::PartialQueryCollector # :nodoc:
      def add_bind(obj)
        super

        # only add binds, no parts - so we need to remove the previously set part
        @parts.pop

        self
      end

      def add_binds(binds, proc_for_binds = nil)
        super

        # only add binds, no parts - so we need to remove the previously set part
        if binds.size == 1
          @parts.pop
        else
          @parts.pop((binds.size * 2) - 1)
        end

        self
      end
    end

    def self.partial_query(values)
      PartialQuery.new(values)
    end

    def self.partial_query_collector
      PartialQueryCollector.new
    end
  end
end
