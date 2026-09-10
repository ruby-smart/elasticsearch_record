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

  # raised when a response was flagged as PARTIAL - which means the returned data is incomplete.
  # Since Elasticsearch 8.19 an ES|QL query no longer fails on (e.g.) an unavailable shard, but
  # succeeds with whatever it could collect and sets the +is_partial+ flag instead.
  #
  # see @ ElasticsearchRecord.error_on_partial_results
  class PartialResultsError < ElasticsearchRecordError
    def initialize(gate)
      super("the '#{gate}' response was flagged as PARTIAL - the returned data is incomplete!\nSet `ElasticsearchRecord.error_on_partial_results = false` to ignore this, or provide `allow_partial_results: false` to fail the query on the cluster instead.")
    end
  end
end