# frozen_string_literal: true

module ElasticsearchRecord # :nodoc:
  module Relation
    class QueryClauseTree
      delegate :any?, :empty?, :key?, to: :predicates

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