# frozen_string_literal: true

module ElasticsearchRecord
  module Instrumentation
    extend ActiveSupport::Autoload

    autoload :ControllerRuntime
    autoload :LogSubscriber
    autoload :Railtie
  end
end

ActiveSupport.on_load(:active_record) do
  # load Instrumentation
  require 'elasticsearch_record/instrumentation/railtie'
  require 'elasticsearch_record/instrumentation/log_subscriber'
end