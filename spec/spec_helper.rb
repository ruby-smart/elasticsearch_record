# frozen_string_literal: true

# NOTE: 'support/elasticsearch' assigns ActiveRecord::Base.configurations and then
# requires 'elasticsearch_record' - the order matters, see the comment in that file.
require_relative "support/elasticsearch"
require_relative "support/test_index"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Examples tagged +:elasticsearch+ need a live cluster - skip rather than fail
  # when none is reachable, so the suite stays runnable offline.
  config.before(:each, :elasticsearch) do
    unless ElasticsearchSpec.available?
      skip "no Elasticsearch at #{ElasticsearchSpec::CONFIG['host']} (#{ElasticsearchSpec.unavailable_reason})"
    end
  end
end
