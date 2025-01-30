# frozen_string_literal: true

module ElasticsearchRecord
  module Instrumentation
    # attach to ElasticsearchRecord related events
    class LogSubscriber < ActiveSupport::LogSubscriber

      IGNORE_PAYLOAD_NAMES = %w[SCHEMA EXPLAIN EXCLUDE]

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

        # nice feature: displays the REAL query-time from elasticsearch response
        # this is handled through the +::ActiveRecord::ConnectionAdapters::ElasticsearchAdapter#api+ method
        if payload[:statistics].present?
          name = "#{name} (took: #{payload[:statistics][:took].round(1)}ms)" if payload[:statistics][:took]
        end

        # build query
        query = payload[:arguments].inspect.gsub(/:(\w+)=>/, '\1: ').truncate((payload[:truncate] || 1000), omission: color(' (pruned)', RED))

        # final coloring
        name  = color(name, name_color(payload[:name]), bold: true)
        query = color(query, gate_color(payload[:gate], payload[:name]), bold: true) if colorize_logging

        debug "  #{name} #{query.presence || '-/-'}"
      end

      private

      def name_color(name)
        if name.blank? || name.match(/^[\p{Lu}\ ]+$/) # uppercase letters only : API, DROP, CREATE, ...
          MAGENTA
        else
          CYAN
        end
      end

      def gate_color(gate, name)
        case gate.to_s
          # SELECTS
        when 'get', 'mget', 'search', 'msearch', 'count', 'exists', 'sql.query'
          BLUE
          # DELETES
        when 'delete', 'delete_by_query'
          RED
          # CREATES
        when 'create', 'reindex'
          GREEN
          # UPDATES
        when 'update', 'update_by_query'
          YELLOW
          # MIXINS
        when /indices\.\w+/, 'bulk', 'index'
          if name.end_with?('Pit Delete')
            RED
          else
            WHITE
          end
        else
          MAGENTA
        end
      end
    end
  end
end

ElasticsearchRecord::Instrumentation::LogSubscriber.attach_to :elasticsearch_record