# frozen_string_literal: true

require 'elasticsearch_record/query'

module Arel # :nodoc: all
  module Collectors
    class ElasticsearchQuery < ::ElasticsearchRecord::Query

      # defines if the query is preparable.
      # used by the default Arel process ...
      # @!attribute Boolean
      attr_accessor :preparable

      # defines a claim Struct, which will be executed through the +#claim+ method
      Claim = ::Struct.new(:action, :args, :block) {
        def key
          args[0].is_a?(Symbol) ? args[0] : nil
        end
      }

      def initialize
        super
        @stack = []
        # force initialize a body as hash
        @body  ||= {}
      end

      # instead of returning the query hash, we return self
      def value
        self
      end

      # send a proposal to this query -
      # @param [ElasticsearchRecord::Query::Claim] claim
      def claim(claim)
        case claim.action
        when :index
          # change the index name
          @index = claim.args[0]
        when :type
          # change the query type
          @type = claim.args[0]
        when :status
          # change the query status
          @status = claim.args[0]
        when :columns
          # change the query columns
          @columns = claim.args[0]
        when :argument
          # adds / sets any argument
          @arguments[claim.args[0]] = claim.args[1]
        when :body
          # set the body var
          @body = claim.args[0]
        when :assign
          # calls a assign on the body
          assign(*claim.args)

          if claim.block.present?
            raise "Unsupported claim key: '#{claim.args[0]}' for provided block. Provide a Symbol as key!" unless claim.key

            scope(claim.key) do
              claim.block.call
            end
          end
        else
          raise "Unsupported claim action: #{claim.action}"
        end
      end

      alias :<< :claim

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

      private

      def parent
        return @body if @stack.length <= 1
        @body.dig(*@stack[0..-2])
      end

      def assign(*args)
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
          self.current = self.current.to_s + args[0].to_s
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
