# frozen_string_literal: true

module ElasticsearchRecord
  module Extensions
    module Relation
      def self.extended(base)
        base.extend ::ElasticsearchRecord::Relation::CoreMethods
        base.extend ::ElasticsearchRecord::Relation::CalculationMethods
        base.extend ::ElasticsearchRecord::Relation::QueryMethods
        base.extend ::ElasticsearchRecord::Relation::ResultMethods
        base.extend ::ElasticsearchRecord::Relation::ValueMethods
      end
    end
  end
end