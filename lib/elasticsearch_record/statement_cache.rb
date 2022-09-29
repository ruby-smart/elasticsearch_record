# frozen_string_literal: true

module ElasticsearchRecord
  class StatementCache < ActiveRecord::StatementCache

    class PartialQuery < ActiveRecord::StatementCache::PartialQuery # :nodoc:

      def sql_for(binds, connection)
        vals = @values.dup

        Debugger.warn(@values,"@values - #{@values[0].class}")

        @indexes.each { |i|
          value = binds.shift
          if ActiveModel::Attribute === value
            value = value.value_for_database
          end

          val = connection.quote(value)

          # replace args for the values
          # cmd, args, block = @values[i]
          vals[i][1] = [val]
        }

        # build a new query collector
        collector = ::Arel::Collectors::ElasticsearchQuery.new

        vals.each do |claim|
          collector << claim
        end

        collector
      end
    end

    def self.partial_query(values)
      PartialQuery.new(values)
    end
  end
end
