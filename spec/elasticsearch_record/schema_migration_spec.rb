# frozen_string_literal: true

# Covers +ElasticsearchRecord::SchemaMigration+.
#
# The class only overwrites two methods of +ActiveRecord::SchemaMigration+:
# - +#table_name+, so the index name is composed from +ElasticsearchRecord::Base+ (which carries
#   its own +table_name_prefix+ / +table_name_suffix+ from the elasticsearch connection config)
#   instead of from +ActiveRecord::Base+
# - +#versions+, which adds the missing size to the query - without it Elasticsearch applies its
#   DEFAULT size of 10 and the migrator only ever sees the first ten migrations (fixed in 1.8.1)
#
# Everything else is inherited. The examples below therefore focus on those two methods and pin
# which parts of the inherited surface actually work on this adapter.
#
# SAFETY: the migration index is created inside the test namespace (+TestIndex::ALLOWED+) by
# pointing +schema_migrations_table_name+ at it - the suite must never touch a real
# 'schema_migrations' index on the shared cluster.
#
# see @ ElasticsearchRecord::SchemaMigration
# see @ ActiveRecord::SchemaMigration
RSpec.describe ElasticsearchRecord::SchemaMigration, :elasticsearch do
  # PLEASE NOTE: the +:elasticsearch+ tag skips these examples through a +before(:each)+ hook
  # (see spec_helper.rb) - so the index setup must NOT run in a +before(:all)+, which would
  # execute before that hook and blow up instead of skipping.
  before do
    ElasticsearchRecord::Base.schema_migrations_table_name = migrations_table_name
    migration.create_table
  end

  after do
    ElasticsearchRecord::Base.schema_migrations_table_name = 'schema_migrations'
    TestIndex.drop!(migrations_table_name)
  end

  subject(:migration) { described_class.new(connection) }

  let(:connection) { ElasticsearchRecord::Base.connection }

  # stays within +TestIndex::ALLOWED+, so it can never wipe a real migrations index
  let(:migrations_table_name) { "#{TestIndex.name}_migrations" }

  # writes the versions & makes them visible to the following search
  def create_versions(*versions)
    versions.each { |version| migration.create_version(version) }
    connection.refresh_table(migrations_table_name)
  end

  ##############
  # TABLE NAME #
  ##############

  describe '#table_name' do
    it 'resolves the schema_migrations_table_name of ElasticsearchRecord::Base' do
      expect(migration.table_name).to eq(migrations_table_name)
    end

    it 'applies the table_name_prefix & table_name_suffix' do
      ElasticsearchRecord::Base.table_name_prefix = 'pre_'
      ElasticsearchRecord::Base.table_name_suffix = '_suf'

      expect(migration.table_name).to eq("pre_#{migrations_table_name}_suf")
    ensure
      ElasticsearchRecord::Base.table_name_prefix = ''
      ElasticsearchRecord::Base.table_name_suffix = ''
    end

    # THE reason this method is overwritten: the elasticsearch connection carries its OWN
    # +table_name_prefix+ / +table_name_suffix+ (both are config extras of the adapter), so the
    # inherited implementation - which reads them from +ActiveRecord::Base+ - would resolve a
    # completely unrelated index.
    it 'ignores the prefix & suffix of ActiveRecord::Base' do
      ActiveRecord::Base.table_name_prefix = 'other_'
      ActiveRecord::Base.table_name_suffix = '_other'

      expect(migration.table_name).to eq(migrations_table_name)
    ensure
      ActiveRecord::Base.table_name_prefix = ''
      ActiveRecord::Base.table_name_suffix = ''
    end

    it 'ignores the schema_migrations_table_name of ActiveRecord::Base' do
      expect(ActiveRecord::Base.schema_migrations_table_name).to eq('schema_migrations')
      expect(migration.table_name).not_to eq('schema_migrations')
    end
  end

  # inherited, but it is built from the overwritten +#table_name+ at initialization
  describe '#arel_table' do
    it 'is built from the resolved table_name' do
      expect(migration.arel_table).to be_an(Arel::Table)
      expect(migration.arel_table.name).to eq(migrations_table_name)
    end

    # PLEASE NOTE: the arel_table is memoized at INITIALIZE - a later change of the
    # +schema_migrations_table_name+ does not reach an already built instance
    it 'does not follow a later table_name change' do
      arel_table = migration.arel_table
      ElasticsearchRecord::Base.schema_migrations_table_name = 'changed_migrations'

      expect(migration.table_name).to eq('changed_migrations')
      expect(arel_table.name).to eq(migrations_table_name)
    end
  end

  ############
  # VERSIONS #
  ############

  describe '#versions' do
    it 'returns an empty Array without any migration' do
      expect(migration.versions).to eq([])
    end

    it 'returns the stored versions' do
      create_versions('20240101120000', '20240101120001')

      expect(migration.versions).to eq(%w[20240101120000 20240101120001])
    end

    it 'orders the versions ascending' do
      create_versions('20240101120002', '20240101120000', '20240101120001')

      expect(migration.versions).to eq(%w[20240101120000 20240101120001 20240101120002])
    end

    it 'returns Strings' do
      create_versions('20240101120000')

      expect(migration.versions).to all(be_a(String))
    end

    # THE regression this method is overwritten for: a search without an explicit size falls back
    # to the Elasticsearch DEFAULT of 10 - the migrator then believes every migration beyond the
    # tenth is still pending and runs it again.
    # see @ CHANGELOG 1.8.1
    context 'with more than ten migrations' do
      let(:versions) { Array.new(12) { |i| format('202401011200%02d', i) } }

      before { create_versions(*versions) }

      it 'returns every version' do
        expect(migration.versions.size).to eq(12)
        expect(migration.versions).to eq(versions)
      end

      # the inherited implementation builds the very same query WITHOUT the size - pinned here so
      # the regression is visible, not just the fix
      it 'is exactly what the inherited implementation fails to do' do
        arel = Arel::SelectManager.new(migration.arel_table)
        arel.project(migration.arel_table[migration.primary_key])
        arel.order(migration.arel_table[migration.primary_key].asc)

        expect(connection.select_values(arel, 'Base Load').size).to eq(10)
      end
    end

    describe 'the built query' do
      # the size is taken from the index setting - NOT from a hard-coded value
      it 'takes the size from the connections max_result_window' do
        versions = Array.new(5) { |i| format('202401011200%02d', i) }
        create_versions(*versions)

        allow(connection).to receive(:max_result_window).with(migrations_table_name).and_return(3)

        expect(migration.versions).to eq(versions.first(3))
      end

      it 'projects only the primary key & sorts ascending' do
        allow(connection).to receive(:max_result_window).and_return(9999)

        captured = nil
        allow(connection).to receive(:select_values).and_wrap_original do |original, arel, *args|
          captured = connection.to_sql(arel)
          original.call(arel, *args)
        end

        migration.versions

        expect(captured.body).to eq({
                                      _source: ['version'],
                                      sort:    { 'version' => :asc },
                                      size:    9999
                                    })
      end

      it 'instruments the query with the class name' do
        allow(connection).to receive(:select_values).and_return([])

        migration.versions

        expect(connection).to have_received(:select_values).with(anything, "#{described_class} Load")
      end
    end
  end

  #######################
  # INHERITED BEHAVIOUR #
  #######################

  describe 'the inherited surface' do
    it 'uses "version" as primary key' do
      expect(migration.primary_key).to eq('version')
    end

    describe '#create_table' do
      it 'creates the index with a version mapping' do
        expect(connection.table_exists?(migrations_table_name)).to be(true)
        expect(connection.table_mappings(migrations_table_name).dig('properties', 'version')).to be_present
      end

      # it is called on every migration run - a second call must not raise
      it 'does nothing for an already existing index' do
        expect { migration.create_table }.not_to raise_error
        expect(connection.table_exists?(migrations_table_name)).to be(true)
      end
    end

    describe '#drop_table' do
      it 'removes the index' do
        migration.drop_table

        expect(connection.table_exists?(migrations_table_name)).to be(false)
      end

      it 'does not raise for a missing index' do
        migration.drop_table

        expect { migration.drop_table }.not_to raise_error
      end
    end

    describe '#table_exists?' do
      it 'is true for the created index' do
        expect(migration.table_exists?).to be(true)
      end

      it 'is false after the index was dropped' do
        migration.drop_table

        expect(migration.table_exists?).to be(false)
      end
    end

    describe '#create_version' do
      # the insert runs through +Arel::InsertManager+ and the ES visitor - see
      # +Arel::Visitors::ElasticsearchQuery#visit_Create+
      it 'stores the provided version' do
        create_versions('20240101120000')

        expect(migration.versions).to eq(['20240101120000'])
      end

      it 'refreshes the index, so the version is instantly resolvable' do
        migration.create_version('20240101120000')

        expect(migration.versions).to eq(['20240101120000'])
      end
    end

    describe '#integer_versions' do
      it 'casts every version to an Integer' do
        create_versions('20240101120000', '20240101120001')

        expect(migration.integer_versions).to eq([20240101120000, 20240101120001])
      end
    end

    describe '#normalized_versions' do
      it 'normalizes every version' do
        create_versions('7', '20240101120000')

        expect(migration.normalized_versions).to eq(%w[20240101120000 007])
      end
    end

    describe '#normalize_migration_number' do
      it 'pads a number to at least three digits' do
        expect(migration.normalize_migration_number(7)).to eq('007')
        expect(migration.normalize_migration_number('20240101120000')).to eq('20240101120000')
      end
    end
  end

  # These inherited methods build Arel the ES visitor cannot compile. They are pinned as-is
  # (NOT as desired behaviour) so a future fix shows up as a failing example here.
  describe 'the inherited surface that Elasticsearch cannot serve' do
    # +ActiveRecord::SchemaMigration#count+ projects +Arel::Nodes::Count+ - there is no
    # +visit_Arel_Nodes_Count+, so the visitor refuses to build a wrong query.
    # HINT: +migration.versions.size+ is the working alternative.
    # see @ Arel::Visitors::ElasticsearchBase#method_missing
    describe '#count' do
      it 'raises an UnsupportedVisitError' do
        create_versions('20240101120000')

        expect { migration.count }
          .to raise_error(Arel::Visitors::ElasticsearchBase::UnsupportedVisitError, /visit_Arel_Nodes_Count/)
      end
    end

    # +ActiveRecord::SchemaMigration#delete_version+ builds a +DeleteManager+ whose relation stays
    # a plain +Arel::Table+ - the visitor only supports a delete-BY-QUERY and raises for that shape.
    # CONSEQUENCE: rolling a migration back cannot remove its version.
    # see @ Arel::Visitors::ElasticsearchQuery#visit_Arel_Nodes_DeleteStatement
    describe '#delete_version' do
      it 'raises a NotImplementedError' do
        create_versions('20240101120000')

        expect { migration.delete_version('20240101120000') }.to raise_error(NotImplementedError)
      end

      it 'leaves the version in place' do
        create_versions('20240101120000')

        expect { migration.delete_version('20240101120000') }.to raise_error(NotImplementedError)
        expect(migration.versions).to eq(['20240101120000'])
      end
    end

    describe '#delete_all_versions' do
      it 'raises through the first delete_version' do
        create_versions('20240101120000')

        expect { migration.delete_all_versions }.to raise_error(NotImplementedError)
      end

      it 'does not raise without any version' do
        expect { migration.delete_all_versions }.not_to raise_error
      end
    end
  end

  ########################
  # ADAPTER INTEGRATION  #
  ########################

  describe 'the adapters #schema_migration' do
    it 'returns an ElasticsearchRecord::SchemaMigration' do
      expect(connection.schema_migration).to be_a(described_class)
    end

    it 'resolves the elasticsearch migrations table' do
      expect(connection.schema_migration.table_name).to eq(migrations_table_name)
    end

    # PLEASE NOTE: the adapter builds a NEW instance on every call - so the memoized +arel_table+
    # of a previously resolved instance is never reused
    it 'builds a new instance on every call' do
      expect(connection.schema_migration).not_to equal(connection.schema_migration)
    end
  end
end
