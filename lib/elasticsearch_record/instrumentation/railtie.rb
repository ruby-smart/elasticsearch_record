# frozen_string_literal: true

module ElasticsearchRecord
  module Instrumentation
    class Railtie < ::Rails::Railtie
      initializer "elasticsearch_record.instrumentation" do |_app|
        require 'elasticsearch_record/instrumentation/log_subscriber'
        require 'elasticsearch_record/instrumentation/controller_runtime'

        ActiveSupport.on_load(:action_controller) do
          include ElasticsearchRecord::Instrumentation::ControllerRuntime
        end
      end
    end
  end
end