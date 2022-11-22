# frozen_string_literal: true

module Arel # :nodoc: all
  module Visitors
    module ElasticsearchBase
      extend ActiveSupport::Concern

      class UnsupportedVisitError < StandardError
        def initialize(method_name)
          super "Unsupported method: '#{method_name}'. Construct an Arel node instead!"
        end
      end

      included do
        attr_accessor :connection
        attr_accessor :collector
      end

      class_methods do
        def simple_dispatch_cache
          @simple_dispatch_cache ||= Hash.new do |hash, klass|
            hash[klass] = "visit_#{(klass.name.demodulize || 'unknown')}"
          end
        end
      end

      def initialize(connection)
        super()
        @connection = connection

        # required for nested assignment.
        # see +#assign+ method
        @nested      = false
        @nested_args = []
      end

      def dispatch_as(mode)
        current, @dispatch = @dispatch, (mode == :simple ? self.class.simple_dispatch_cache : self.class.dispatch_cache)

        res = yield

        @dispatch = current

        res
      end

      def compile(node, collector = Arel::Collectors::ElasticsearchQuery.new)
        # we don't need to forward the collector each time - we just set it and always access it, when we need.
        self.collector = collector

        # so we just visit the first node without any additionally provided collector ...
        accept(node)

        # ... and return the final result
        self.collector.value
      end

      private

      # auto prevent visits on missing nodes
      def method_missing(method, *args, &block)
        raise(UnsupportedVisitError, method.to_s) if method.to_s[0..4] == 'visit'

        super
      end

      # collects and returns provided object 'visit' result.
      # returns an array of results if a array was provided.
      # does not validate if the object is present...
      # @param [Object] obj
      # @param [Symbol] method (default: :visit)
      # @return [Object,nil]
      def collect(obj, method = :visit)
        if obj.is_a?(Array)
          obj.map { |o| self.__send__(method, o) }
        elsif obj.present?
          self.__send__(method, obj)
        else
          nil
        end
      end

      # resolves the provided object 'visit' result.
      # check if the object is present.
      # does not return any values
      # @param [Object] obj
      # @param [Symbol] method (default: :visit)
      # @return [nil]
      def resolve(obj, method = :visit)
        return unless obj.present?

        objects = obj.is_a?(Array) ? obj : [obj]
        objects.each do |obj|
          self.__send__(method, obj)
        end

        nil
      end

      # assign provided args on the collector.
      # The TOP-Level assignment must be a (key, value) while sub-assignments will be collected by provided block.
      # Sub-assignments will never claim on the query but 'merged' to the TOP-assignment.
      #
      #   assign(:query, {}) do
      #    #... do some stuff ...
      #    assign(:bool, {}) do
      #     assign(:x,99)
      #     assign({y: 45})
      #    end
      #   end
      #   #> query: {bool: {x: 99, y: 45}}
      def assign(*args)
        # resolve possible TOP-LEVEL assignment
        key, value = args

        # if a block was provided we want to collect the nested assignments
        if block_given?
          raise ArgumentError, "Unsupported assignment value for provided block (#{key}). Provide any Object as value!" if value.nil?

          # set nested state to tell all nested assignments to not claim it's values
          old_nested, @nested           = @nested, true
          old_nested_args, @nested_args = @nested_args, []

          # call block, but don't interact with its return.
          # nested args are separately stored
          yield

          # restore nested state
          @nested = old_nested

          # assign nested args
          @nested_args.each do |nested_args|
            # ARRAY assignment
            case value
            when Array
              if nested_args[0].is_a?(Array)
                nested_args[0].each do |nested_arg|
                  value << nested_arg
                end
              elsif nested_args[0].nil?
                # handle special case: nil delegates to the value = nested_args[1]
                value << nested_args[1]
              else
                value << nested_args[0]
              end
            when Hash
              if nested_args[0].is_a?(Hash)
                value.merge!(nested_args[0])
              elsif value[nested_args[0]].is_a?(Hash) && nested_args[1].is_a?(Hash)
                value[nested_args[0]] = value[nested_args[0]].merge(nested_args[1])
              elsif value[nested_args[0]].is_a?(Array) && nested_args[1].is_a?(Array)
                value[nested_args[0]] += nested_args[1]
              elsif nested_args[1].nil?
                value.delete(nested_args[0])
              elsif nested_args[0].nil? && nested_args[1].is_a?(Hash)
                # handle special case: nil delegates to the value = nested_args[1]
                value.merge!(nested_args[1])
              else
                value[nested_args[0]] = nested_args[1]
              end
            when String
              if nested_args[0].is_a?(Array)
                value = value + nested_args[0].map(&:to_s).join
              elsif nested_args[0].nil?
                # handle special case: nil delegates to the value = nested_args[1]
                if nested_args[1].is_a?(Array)
                  value = value + nested_args[1].map(&:to_s).join
                else
                  value = value + nested_args[1].to_s
                end
              else
                value = value + nested_args[0].to_s
              end
            else
              value = nested_args[0] unless nested_args.blank?
            end
          end

          # clear nested args
          @nested_args = old_nested_args
        elsif args.compact.blank?
          return
        end

        # for nested assignments we only want the assignable args - no +claim+ on the query!
        if @nested
          @nested_args << args
          return
        end

        raise ArgumentError, "Unsupported assign key: '#{key}' for provided block. Provide a Symbol as key!" unless key.is_a?(Symbol)

        claim(:assign, key, value)
      end

      # creates and sends a new claim to the collector.
      # @param [Symbol] action - claim action (:index, :type, :status, :argument, :body, :assign)
      # @param [Array] args - either <key>,<value> or <Hash{<key> => <value>, ...}> or <Array>
      def claim(action, *args)
        self.collector << [action, args]

        # IMPORTANT: always return nil, to prevent unwanted assignments
        nil
      end

      ###########
      # HELPERS #
      ###########

      def unboundable?(value)
        value.respond_to?(:unboundable?) && value.unboundable?
      end

      def invalid?(value)
        value == '1=0'
      end

      def quote(value)
        return value if Arel::Nodes::SqlLiteral === value
        connection.quote value
      end

      # assigns a failed status to the current query
      def failed!
        claim(:status, ElasticsearchRecord::Query::STATUS_FAILED)

        nil
      end
    end
  end
end
