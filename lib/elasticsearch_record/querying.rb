module ElasticsearchRecord
  module Querying
    extend ActiveSupport::Concern

    module ClassMethods
      # define additional METHODS to be delegated to the Relation
      # @see ::ActiveRecord::Querying::QUERYING_METHODS
      ES_QUERYING_METHODS = [
        :query,
        :filter,
        :must,
        :must_not,
        :should,
        :aggregate
      ].freeze # :nodoc:
      delegate(*ES_QUERYING_METHODS, to: :all)
    end
  end
end
