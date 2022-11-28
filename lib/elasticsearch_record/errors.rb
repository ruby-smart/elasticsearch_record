# frozen_string_literal: true

module ElasticsearchRecord
  # Generic ElasticsearchRecord exception class.
  class ElasticsearchRecordError < StandardError
  end

  class ResponseResultError < ElasticsearchRecordError
    def initialize(expected, result)
      super("expected response-result failed!\nreturned: '#{result}', but should be '#{expected}'")
    end
  end
end