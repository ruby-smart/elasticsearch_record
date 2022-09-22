# frozen_string_literal: true

module Arel # :nodoc: all
  module Nodes
    class SelectQuery < Unary

      def left
        expr[0]
      end

      def right
        expr[1]
      end

      def opts
        expr[2]
      end
    end
  end
end
