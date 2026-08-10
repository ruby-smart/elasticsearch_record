# frozen_string_literal: true

# Connection setup for the specs.
#
# IMPORTANT: +ElasticsearchRecord::Base+ calls +connects_to database: { writing: :elasticsearch, ... }+
# at class-definition time, so the configuration MUST be assigned *before* 'elasticsearch_record'
# is required - and it must live under the current AR environment (+default_env+ unless RAILS_ENV/
# RACK_ENV is set) using the connection name +elasticsearch+.
require 'active_record'

module ElasticsearchSpec
  # The index used by the specs. It is created & dropped by the suite.
  #
  # WARNING: never point this at an index you care about - +TestIndex+ drops it.
  TEST_INDEX = ENV.fetch('ES_TEST_INDEX', 'elasticsearch_record_test')

  # Connection settings, overridable via ENV so CI can point somewhere else.
  CONFIG = {
    'adapter'  => 'elasticsearch',
    'host'     => ENV.fetch('ES_HOST', 'localhost:9400'),
    'user'     => ENV.fetch('ES_USER', 'elastic'),
    'password' => ENV.fetch('ES_PASSWORD', '7rpRj7cKnlHWOd5DNeJM')
  }.freeze

  class << self
    # true if the configured cluster is reachable.
    # Used to skip (instead of fail) the suite when no server is running.
    def available?
      return @available if defined?(@available)

      @available = begin
        ElasticsearchRecord::Base.connection.verify!
        true
      rescue StandardError => e
        @unavailable_reason = "#{e.class}: #{e.message}"
        false
      end
    end

    def unavailable_reason
      @unavailable_reason
    end

    def connection
      ElasticsearchRecord::Base.connection
    end
  end
end

ActiveRecord::Base.configurations = {
  ActiveRecord::ConnectionHandling::DEFAULT_ENV.call => {
    'elasticsearch' => ElasticsearchSpec::CONFIG
  }
}

require 'elasticsearch_record'
