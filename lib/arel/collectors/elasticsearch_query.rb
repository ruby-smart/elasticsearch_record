# frozen_string_literal: true

require 'elasticsearch_record/query'

module Arel # :nodoc: all
  module Collectors
    class ElasticsearchQuery < ::ElasticsearchRecord::Query
      def initialize
        super

        # force initialize a body as hash
        @body ||= {}

        # stack is used to point on a specific hash node
        @stack = []
      end

      # send a proposal to this query -
      # @param [Symbol] action - the claim action
      # @param [Array] args - args to claim
      # @param [Proc] block - a optional block to create a nested scope on the current provided key
      def claim(action, *args, &block)
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
        when :argument
          # adds / sets any argument
          @arguments[args[0]] = args[1]
        when :body
          # set the body var
          @body = args[0]
        when :assign
          # calls a assign on the body
          assign(*args)

          if block_given?
            raise "Unsupported claim key: '#{args[0]}' for provided block. Provide a Symbol as key!" unless args[0].is_a?(Symbol)

            scope(args[0]) do
              block.call
            end
          end
        else
          raise "Unsupported claim action: #{action}"
        end
      end

      def <<(claim)
        Debugger.debug(claim,"receiving a claim")

        self.claim(claim[0], *claim[1], &claim[2])
      end

      def current
        @current ||= @stack.any? ? @body.dig(*@stack) : @body
      end

      def current=(value)
        if (key = @stack.last).present?
          __send__(:parent)[key] = value
        else
          @body = value
        end

        # IMPORTANT! Reset current
        @current = nil
      end

      def value
        self
      end

      private

      def parent
        return @body if @stack.length <= 1
        @body.dig(*@stack[0..-2])
      end

      def assign(*args)
        # check for special provided key, to claim through an assign
        if args[0] == :__query__
          if args[1].is_a?(Array)
            args[1].each do |arg|
              key = arg.keys.first
              claim(key, arg[key])
            end
          else
            key = args[1].keys.first
            claim(key, args[1][key])
          end

          return self
        end

        if self.current.is_a?(Array)
          if args[0].is_a?(Array)
            self.current += args[0]
          else
            self.current << args[0]
          end
        elsif self.current.is_a?(Hash)
          if args[0].is_a?(Hash)
            self.current = self.current.merge(args[0])
          elsif self.current[args[0]].is_a?(Hash) && args[1].is_a?(Hash)
            self.current[args[0]] = self.current[args[0]].merge(args[1])
          elsif args[1].nil?
            self.current.delete(args[0])
          else
            self.current[args[0]] = args[1]
          end
        elsif self.current.is_a?(String)
          if args[0].is_a?(Array)
            self.current = self.current.to_s + args[0].map(&:to_s).join
          else
            self.current = self.current.to_s + args[0].to_s
          end
        else
          self.current = args[0]
        end

        self
      end

      def scope(key)
        @stack << key
        @current = nil

        yield

        @stack.pop
        @current = nil
      end
    end
  end
end
