# frozen_string_literal: true

module Arel # :nodoc: all
  module Nodes
    class SelectAgg < Unary

      def left
        expr[0]
      end

      def right
        return expr[1].reduce({}) { |m, data| data ? m.merge(data) : m } if expr[1].is_a?(Array)

        expr[1]
      end

      def opts
        expr[2]
      end
    end
  end
end
