module ElasticsearchRecord
  module Relation
    module ValueMethods
      # holds the query kind
      def kind_value
        @values.fetch(:kind, nil)
      end

      def kind_value=(value)
        # checks if records are already loaded - in this case we cannot mutate the query anymore
        assert_mutability!

        @values[:kind] = value.to_sym
      end

      def configure_value
        @values.fetch(:configure, {})
      end

      def configure_value=(value)
        assert_mutability!

        @values[:configure] = value
      end

      def query_clause
        @values.fetch(:query, ElasticsearchRecord::Relation::QueryClauseTree.empty)
      end

      def query_clause=(value)
        assert_mutability!

        @values[:query] = value
      end

      def aggs_clause
        @values.fetch(:aggs, ElasticsearchRecord::Relation::QueryClauseTree.empty)
      end

      def aggs_clause=(value)
        assert_mutability!

        @values[:aggs] = value
      end

      # overwrite the limit_value setter, to provide a special behaviour of auto-setting the +max_result_window+.
      def limit=(limit)
        if limit == '__max__' || (limit.nil? && delegate_query_nil_limit?)
          super(max_result_window)
        else
          super
        end
      end

      private

      # alternative method to avoid redefining the const +VALID_UNSCOPING_VALUES+
      def _valid_unscoping_values
        Set.new(ActiveRecord::Relation::VALID_UNSCOPING_VALUES.to_a + [:kind, :configure, :query, :aggs])
      end
    end
  end
end