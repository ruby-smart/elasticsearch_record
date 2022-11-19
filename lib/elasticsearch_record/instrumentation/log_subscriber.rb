# frozen_string_literal: true

module ElasticsearchRecord
  module Instrumentation
    # attach to ElasticsearchRecord related events
    class LogSubscriber < ActiveSupport::LogSubscriber

      IGNORE_PAYLOAD_NAMES = %w[SCHEMA EXPLAIN]

      def self.runtime=(value)
        Thread.current["elasticsearch_record_runtime"] = value
      end

      def self.runtime
        Thread.current["elasticsearch_record_runtime"] ||= 0
      end

      def self.reset_runtime
        rt, self.runtime = runtime, 0
        rt
      end

      # Intercept `query.elasticsearch` events, and display them in the Rails log
      def query(event)
        self.class.runtime += event.duration

        return unless logger.debug?

        payload = event.payload
        return if IGNORE_PAYLOAD_NAMES.include?(payload[:name])

        # build name from several payload data
        name = if payload[:async]
                 "ASYNC #{payload[:name]} (#{payload[:lock_wait].round(1)}ms) (execution time #{event.duration.round(1)}ms)"
               else
                 "#{payload[:name]} (#{event.duration.round(1)}ms)"
               end
        name = "CACHE #{name}" if payload[:cached]

        # nice feature: displays the REAL query-time (_qt)
        name = "#{name} (took: #{payload[:arguments][:_qt].round(1)}ms)" if payload[:arguments][:_qt]

        # build query
        query = payload[:arguments].except(:_qt).inspect.gsub(/:(\w+)=>/, '\1: ').presence || '-'

        # final coloring
        name  = color(name, name_color(payload[:name]), true)
        query = color(query, gate_color(payload[:gate]), true) if colorize_logging

        debug "  #{name} #{query}"
      end

      private

      def name_color(name)
        if name.blank? || name.match(/^[\p{Lu}\ ]+$/) # uppercase letters only : API, DROP, CREATE, ...
          MAGENTA
        else
          CYAN
        end
      end

      def gate_color(gate)
        case gate
          # SELECTS
        when 'core.get', 'core.mget', 'core.search', 'core.msearch', 'core.count', 'core.exists', 'sql.query'
          BLUE
          # DELETES
        when 'core.delete', 'core.delete_by_query'
          RED
          # CREATES
        when 'core.create', 'core.reindex'
          GREEN
          # UPDATES
        when 'core.update', 'core.update_by_query'
          YELLOW
          # MIXINS
        when /indices\.\w+/, 'core.bulk', 'core.index'
          WHITE
        else
          MAGENTA
        end
      end
    end
  end
end

ElasticsearchRecord::Instrumentation::LogSubscriber.attach_to :elasticsearch_record