# frozen_string_literal: true

require "active_record/internal_metadata"

module ElasticsearchRecord
  class InternalMetadata < ::ActiveRecord::InternalMetadata

    # overwrite method to always disable the internal metadata index.
    #
    # Elasticsearch cannot serve the internal metadata table
    # (see +ElasticsearchAdapter#use_metadata_table?+) - but since rails 7.2 the flag is
    # resolved through the database config (default: enabled) instead of the adapter,
    # so a default configuration would suddenly create & write a 'ar_internal_metadata'
    # index on the cluster.
    def enabled?
      false
    end
  end
end
