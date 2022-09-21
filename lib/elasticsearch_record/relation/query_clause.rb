# frozen_string_literal: true

module ElasticsearchRecord # :nodoc:
  module Relation
    class QueryClause
      delegate :any?, :empty?, to: :predicates

      attr_reader :key

      def initialize(key, predicates, opts = {})
        @key       = key
        @predicates = predicates
        @opts       = opts
      end

      def hash
        [self.class, key, predicates, opts].hash
      end

      def ast
        [key, (predicates.one? ? predicates[0] : predicates), opts]
      end

      def +(other)
        ::ElasticsearchRecord::Relation::QueryClause.new(key, predicates + other.predicates, opts.merge(other.opts))
      end

      def -(other)
        ::ElasticsearchRecord::Relation::QueryClause.new(key, predicates - other.predicates, Hash[opts.to_a - other.opts.to_a])
      end

      def |(other)
        ::ElasticsearchRecord::Relation::QueryClause.new(key, predicates | other.predicates, Hash[opts.to_a | other.opts.to_a])
      end

      protected

      attr_reader :predicates
      attr_reader :opts

    end
  end
end