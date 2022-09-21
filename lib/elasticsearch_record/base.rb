require 'elasticsearch'

module ElasticsearchRecord
  class Base < ::ActiveRecord::Base

    include Core
    include ModelSchema
    include Persistence
    include Querying

    self.abstract_class = true
    connects_to database: { writing: :elasticsearch, reading: :elasticsearch }
  end
end