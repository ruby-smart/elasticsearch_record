# frozen_string_literal: true

module ElasticsearchRecord # :nodoc:
  module Relation
    class QueryClauseTree
      delegate :any?, :empty?, :key?, :keys, :each, to: :predicates

      def self.empty
        @empty ||= new({}).freeze
      end

      def initialize(predicates)
        @predicates = predicates
      end

      def key
        :tree
      end

      def hash
        [self.class, predicates].hash
      end

      def ast
        predicates.values.map(&:ast)
      end

      def merge(other)
        dups = dupredicates

        other.each do |key, values|
          if dups.key?(key)
            dups[key] = (dups[key] + values).uniq
          else
            dups[key] = values
          end
        end

        QueryClauseTree.new(dups)
      end

      def [](key)
        return nil unless key?(key)

        dupredicates[key]
      end

      def +(other)
        dups = dupredicates

        if key?(other.key)
          dups[other.key] += other
        else
          dups[other.key] = other
        end

        QueryClauseTree.new(dups)
      end

      def -(other)
        # check for provided :tree
        if other.key == :tree
          scope = self

          (scope.keys & other.keys).each do |key|
            scope -= other[key]
          end

          return scope
        end

        dups = dupredicates

        if key?(other.key)
          dups[other.key] -= other
          dups.delete(other.key) if dups[other.key].blank?
        end

        QueryClauseTree.new(dups)
      end

      def |(other)
        dups = dupredicates

        if key?(other.key)
          dups[other.key] |= other
        else
          dups[other.key] = other
        end

        QueryClauseTree.new(dups)
      end

      def ==(other)
        other.is_a?(::ElasticsearchRecord::Relation::QueryClauseTree) &&
          predicates == other.predicates
      end

      def or(other)
        left = self - other
        common = self - left
        right = other - common

        if left.empty? || right.empty?
          common
        else
          key = other.keys[0]

          left = left[key]
          right = right[key]

          or_clause = Arel::Nodes::Or.new(left, right)

          common.predicates[key] = ElasticsearchRecord::Relation::QueryClause.new(key, [Arel::Nodes::Grouping.new(or_clause)])
          common
        end
      end

      protected

      attr_reader :predicates

      private

      def dupredicates
        # we only dup the hash - no need to dup the lower elements
        predicates.dup
      end
    end
  end
end