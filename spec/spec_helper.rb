# frozen_string_literal: true

require "elasticsearch_record"

# eager-load ActiveRecord, so the gem's on_load patches (select_core, select_manager, ...) apply
ActiveRecord::Base # rubocop:disable Void

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
