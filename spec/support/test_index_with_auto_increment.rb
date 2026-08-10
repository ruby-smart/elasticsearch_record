# frozen_string_literal: true

# Creates / drops the test index that emulates an +auto_increment+ primary key.
#
# The +auto_increment+ is NOT an elasticsearch feature - it is emulated through the +_meta+ node of
# the index mappings: a mapping flagged as +primary_key+ writes a '_meta.primary_key' and, with an
# additionally provided +auto_increment+, a '_meta.auto_increment' holding the START value:
#
#   create_table "settings", force: true do |t|
#     t.mapping :created_at, :date
#     t.mapping :key, :integer do |m|
#       m.primary_key    = true
#       m.auto_increment = 10
#     end
#   end
#
# Every destructive call goes through +TestIndex+, which owns the name guard.
#
# see @ ActiveRecord::ConnectionAdapters::Elasticsearch::CreateTableDefinition#mapping
# see @ ElasticsearchRecord::Persistence::ClassMethods#_insert_with_auto_increment
module TestIndexWithAutoIncrement
  # the +auto_increment+ START value written into the indices +_meta+.
  # The FIRST created record therefore resolves +START + 1+.
  START = 10

  # the mapping that carries the primary_key & auto_increment flags
  PRIMARY_KEY = :key

  class << self
    def name
      "#{ElasticsearchSpec::TEST_INDEX}_auto_increment"
    end

    def connection
      TestIndex.connection
    end

    def exists?
      TestIndex.exists?(name)
    end

    def drop!
      TestIndex.drop!(name)
    end

    # (Re)creates the index with an +auto_increment+ primary key.
    # A different +start+ value may be provided to pin the resolution against it.
    def create!(start = START)
      TestIndex.create!(name) do |t|
        t.mapping :created_at, :date
        t.mapping PRIMARY_KEY, :integer do |m|
          m.primary_key    = true
          m.auto_increment = start
        end
      end
    end

    # returns the CURRENT '_meta.auto_increment' value of the index - this is the value
    # +_insert_with_auto_increment+ resolves the next id from and writes back after an insert.
    # @return [Object, nil]
    def auto_increment
      metas['auto_increment']
    end

    # returns the complete +_meta+ node of the index.
    # @return [Hash]
    def metas
      connection.table_metas(name)
    end

    # builds an anonymous model against this index.
    # @return [Class]
    def model(model_name = 'TestIndexWithAutoIncrementModel')
      Class.new(ElasticsearchRecord::Base) {
        define_singleton_method(:name) { model_name }
      }.tap { |klass|
        klass.table_name = TestIndexWithAutoIncrement.name
        klass.reset_column_information
      }
    end
  end
end
