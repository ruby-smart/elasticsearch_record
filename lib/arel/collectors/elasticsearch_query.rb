# frozen_string_literal: true

require 'elasticsearch_record/query'

module Arel # :nodoc: all
  module Collectors
    class ElasticsearchQuery < ::ElasticsearchRecord::Query

      # required for ActiveRecord
      attr_accessor :preparable

      def initialize
        # force initialize a body as hash
        super(body: {})

        # @binds = []
        @bind_index = 1
      end

      # send a proposal to this query
      # @param [Symbol] action - the claim action
      # @param [Array] args - args to claim
      def claim(action, *args)
        case action
        when :index
          # change the index name
          @index = args[0]
        when :type
          # change the query type
          @type = args[0]
        when :status
          # change the query status
          @status = args[0]
        when :columns
          # change the query columns
          @columns = args[0]
        when :arguments
          # change the query arguments
          @arguments = args[0]
        when :argument
          # adds / sets any argument
          if args.length == 2
            @arguments[args[0]] = args[1]
          else # should be a hash
            @arguments.merge!(args[0])
          end
        when :body
          # set the body var
          @body = args[0]
        when :assign
          # calls a assign on the body
          assign(*args)
        else
          raise "Unsupported claim action: #{action}"
        end
      end

      def <<(claim)
        self.claim(claim[0], *claim[1])
      end

      # used by the +Arel::Visitors::Elasticsearch#compile+ method (and default Arel visitors)
      def value
        self
      end

      # IMPORTANT: For SQL defaults (see @ Arel::Collectors::SubstituteBinds) a value
      # will +not+ be directly assigned (see @ Arel::Visitors::ToSql#visit_Arel_Nodes_HomogeneousIn).
      # instead it will be send as bind and then re-delegated to the SQL collector.
      #
      # This only works for linear SQL-queries and not nested Hashes
      # (otherwise we have to collect those binds, and replace them afterwards).
      #
      # This will be ignored by the ElasticsearchQuery collector, but supports statement caches on the other side
      # (see @ ActiveRecord::StatementCache::PartialQueryCollector)
      def add_bind(bind, &block)
        @bind_index += 1

        self
      end

      # @see Arel::Collectors::ElasticsearchQuery#add_bind
      def add_binds(binds, proc_for_binds = nil, &block)
        @bind_index += binds.size
        self
      end

      private

      # calls a assign on the body
      def assign(key, value)
        # check for special provided key, to claim through an assign
        if key == :__claim__
          if value.is_a?(Array)
            value.each do |arg|
              vkey = arg.keys.first
              claim(vkey, arg[vkey])
            end
          else
            vkey = value.keys.first
            claim(vkey, value[vkey])
          end
        elsif value.nil?
          @body.delete(key)
        else
          @body[key] = value
        end
      end
    end
  end
end
