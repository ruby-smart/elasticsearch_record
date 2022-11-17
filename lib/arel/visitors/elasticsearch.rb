# frozen_string_literal: true

require 'arel/visitors/elasticsearch_base'
require 'arel/visitors/elasticsearch_query'
require 'arel/visitors/elasticsearch_schema'

require 'arel/collectors/elasticsearch_query'

module Arel # :nodoc: all
  module Visitors
    class Elasticsearch < Arel::Visitors::Visitor
      include ElasticsearchBase
      include ElasticsearchQuery
      include ElasticsearchSchema

    end
  end
end
