# frozen_string_literal: true

# Creates / drops the single index the specs are allowed to touch.
#
# The cluster this suite runs against is SHARED with other applications, so this
# helper refuses to drop anything that is not exactly +ElasticsearchSpec::TEST_INDEX+.
# Every destructive call in the suite must go through here.
module TestIndex
  # Guard against a mis-configured ES_TEST_INDEX wiping a real index.
  # Only names matching this may ever be dropped.
  ALLOWED = /\A[a-z0-9_\-]*elasticsearch_record_test[a-z0-9_\-]*\z/

  class UnsafeIndexError < StandardError; end

  class << self
    def name
      ElasticsearchSpec::TEST_INDEX
    end

    def connection
      ElasticsearchSpec.connection
    end

    def exists?(index_name = name)
      connection.table_exists?(index_name)
    end

    # Drops the test index if present - refuses any name outside +ALLOWED+.
    def drop!(index_name = name)
      assert_safe!(index_name)
      return false unless exists?(index_name)

      connection.drop_table(index_name)
      true
    end

    # (Re)creates the test index with a small, known mapping.
    #
    # A different +index_name+ (and mapping, through the block) may be provided for specs that
    # need a second index - it still has to match +ALLOWED+, so it stays within the test namespace.
    def create!(index_name = name, &block)
      assert_safe!(index_name)
      drop!(index_name)

      if block
        connection.create_table(index_name, &block)
      else
        connection.create_table(index_name) do |t|
          t.mapping :name, :keyword
          t.mapping :count, :integer
          t.mapping :active, :boolean
          t.mapping :created_at, :date

          t.setting 'index.number_of_shards', '1'
          t.setting 'index.number_of_replicas', '0'
        end
      end

      index_name
    end

    private

    # Refuses to operate on anything that is not clearly the test index.
    def assert_safe!(index_name = name)
      return if index_name.match?(ALLOWED)

      raise UnsafeIndexError,
            "Refusing to modify index #{index_name.inspect} - the spec suite may only touch " \
            "indices matching #{ALLOWED.inspect}. Other applications share this cluster."
    end
  end
end
