# frozen_string_literal: true

require 'coveralls'
Coveralls.wear! do
  # exclude specs
  add_filter %r{^/spec/}
  add_filter %r{patches}
  add_filter 'lib/elasticsearch_record.rb'

  # GROUPS
  add_group "ConnectionAdapter", 'connection_adapters/elasticsearch'
  add_group "ElasticsearchRecord", 'elasticsearch_record/'
  add_group "Arel", 'arel/'

  self.formatter = SimpleCov::Formatter::HTMLFormatter unless ENV.fetch('CI', nil)
end