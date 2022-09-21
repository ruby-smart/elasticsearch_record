# frozen_string_literal: true

require 'active_support/core_ext/module/attr_internal'

module ElasticsearchRecord
  module Instrumentation
    # Hooks into ActionController to display ElasticsearchRecord runtime
    # @see https://github.com/rails/rails/blob/master/activerecord/lib/active_record/railties/controller_runtime.rb
    #
    module ControllerRuntime
      extend ActiveSupport::Concern

      protected

      attr_internal :elasticsearch_record_runtime

      def cleanup_view_runtime
        elasticsearch_rt_before_render    = ElasticsearchRecord::Instrumentation::LogSubscriber.reset_runtime
        runtime                           = super
        elasticsearch_rt_after_render     = ElasticsearchRecord::Instrumentation::LogSubscriber.reset_runtime
        self.elasticsearch_record_runtime = elasticsearch_rt_before_render + elasticsearch_rt_after_render
        runtime - elasticsearch_rt_after_render
      end

      def append_info_to_payload(payload)
        super
        payload[:elasticsearch_record_runtime] = (elasticsearch_record_runtime || 0) + ElasticsearchRecord::Instrumentation::LogSubscriber.reset_runtime
      end

      module ClassMethods
        def log_process_action(payload)
          messages, elasticsearch_runtime = super, payload[:elasticsearch_record_runtime]
          messages << ("ElasticsearchRecord: %.1fms" % elasticsearch_runtime.to_f) if elasticsearch_runtime
          messages
        end
      end
    end
  end
end